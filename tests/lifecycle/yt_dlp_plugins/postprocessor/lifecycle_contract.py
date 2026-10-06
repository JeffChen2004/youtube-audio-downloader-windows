"""Test-only probes loaded by the bundled executable; never register in production."""

import json
from pathlib import Path

from yt_dlp import YoutubeDL
from yt_dlp.dependencies import mutagen
from yt_dlp.postprocessor.common import PostProcessor
from yt_dlp.utils import PostProcessingError
from yt_dlp.version import __version__
from yt_dlp_plugins.postprocessor.source_metadata import (
    SOURCE_METADATA_SUCCESS_KEY, SourceMetadataPP,
)

__all__ = ['LifecycleContractPP']


def event(pp, info, phase, **values):
    pp._downloader.to_stdout('__YAD_LIFECYCLE__' + json.dumps(
        {'id': info['id'], 'phase': phase, **values}, separators=(',', ':')))


def project_path(original, result):
    """Future update contract on a test snapshot; never mutate runtime filepath."""
    if result['final_location'] in ('missing', 'unknown'):
        if result['verified_final_path'] is not None:
            raise PostProcessingError('impossible fixture final-path contract')
        return original
    return result['verified_final_path'] or original


def source_failure_checks(pp, info):
    """Exercise real invalid-media and raw writer-exception paths without touching downloads."""
    invalid = Path(pp._downloader.prepare_filename(info)).with_name('unit-invalid.opus')
    invalid.write_bytes(b'not an opus stream')
    source = SourceMetadataPP(pp._downloader)
    fixture = {**info, 'filepath': str(invalid), 'ext': 'opus', SOURCE_METADATA_SUCCESS_KEY: True}
    try:
        source.run(fixture)
    except Exception as error:
        if SOURCE_METADATA_SUCCESS_KEY in fixture:
            raise PostProcessingError('invalid media retained success marker')
        event(pp, info, 'marker_check', case='invalid_media', marker=False, exception=type(error).__name__)
    else:
        raise PostProcessingError('invalid media unexpectedly accepted')
    original = source._write_opus
    def fail_save(*args):
        raise OSError('fixture disk write failed')
    source._write_opus = fail_save
    fixture[SOURCE_METADATA_SUCCESS_KEY] = True
    try:
        source.run(fixture)
    except OSError:
        if SOURCE_METADATA_SUCCESS_KEY in fixture:
            raise PostProcessingError('write failure retained success marker')
        event(pp, info, 'marker_check', case='raw_write_failure', marker=False, exception='OSError')
    else:
        raise PostProcessingError('write failure unexpectedly accepted')
    finally:
        source._write_opus = original
        invalid.unlink()


def path_contract_checks(pp, info):
    original, verified = 'fixture-original.opus', 'fixture-core-verified.opus'
    statuses = ['succeeded', 'unchanged', 'rejected', 'failed', 'requires_attention']
    for status in statuses:
        result = {'rename_status': status, 'final_location': 'source', 'verified_final_path': verified}
        if project_path(original, result) != verified:
            raise PostProcessingError('fixture discarded Core verified path')
    for location in ('missing', 'unknown'):
        if project_path(original, {'final_location': location, 'verified_final_path': None}) != original:
            raise PostProcessingError('fixture guessed an unverified path')
        try:
            project_path(original, {'final_location': location, 'verified_final_path': verified})
        except PostProcessingError:
            pass
        else:
            raise PostProcessingError('fixture accepted an impossible verified-path claim')
    event(pp, info, 'path_contract', verified_path_used=True, impossible_claim_rejected=True)


class FixtureSourcePP(SourceMetadataPP):
    def __init__(self, downloader, scenario):
        super().__init__(downloader, client='fixture', preserve='true')
        self.scenario = scenario

    def run(self, info):
        first = info['id'] == 'first'
        original_path, original_ext = info['filepath'], info['ext']
        if first and self.scenario in ('write_failure', 'raw_write_failure', 'unsupported', 'invalid_media'):
            # Prove stale-marker removal on real failure branches.
            info[SOURCE_METADATA_SUCCESS_KEY] = True
        try:
            if first and self.scenario in ('write_failure', 'raw_write_failure'):
                writer = self._write_opus
                def fail_write(*args):
                    if self.scenario == 'raw_write_failure':
                        raise OSError('fixture metadata raw save failed')
                    raise PostProcessingError('fixture metadata save failed')
                self._write_opus = fail_write
                try:
                    return super().run(info)
                finally:
                    self._write_opus = writer
            if first and self.scenario == 'unsupported':
                info['ext'] = 'unsupported'
            if first and self.scenario == 'invalid_media':
                # No media corruption: exercise the real missing/invalid path check.
                info['filepath'] = str(Path(info['filepath']).with_name('missing.opus'))
            return super().run(info)
        finally:
            info['filepath'], info['ext'] = original_path, original_ext
            event(self, info, 'source', marker=info.get(SOURCE_METADATA_SUCCESS_KEY) is True)


class FixtureDownstreamPP(PostProcessor):
    def __init__(self, downloader, scenario):
        super().__init__(downloader)
        self.scenario = scenario

    def run(self, info):
        if info.get(SOURCE_METADATA_SUCCESS_KEY) is not True:
            event(self, info, 'admission', admitted=False, domain_entered=False,
                  error='upstream_not_finalized', rename_status='not_requested')
            raise PostProcessingError('fixture upstream metadata not finalized')
        path = Path(info['filepath'])
        media = mutagen.File(path)
        if path.suffix == '.opus':
            verified = media.get('SOURCE_CLIENT') == ['fixture'] and media.get('TITLE') == [info['title']]
        else:
            verified = (bytes(media.tags['----:com.apple.iTunes:SOURCE_CLIENT'][0]) == b'fixture'
                        and media.tags['\xa9nam'] == [info['title']])
        if info['id'] == 'first' and self.scenario == 'bad_tags':
            verified = False
        if not verified:
            event(self, info, 'admission', admitted=False, domain_entered=False,
                  error='required_tags_invalid', rename_status='not_requested')
            raise PostProcessingError('fixture required final tags invalid')
        archive = Path(self.get_param('download_archive'))
        event(self, info, 'admission', admitted=True, domain_entered=True,
              archive_before=archive.read_text(encoding='utf-8').splitlines() if archive.exists() else [],
              cover_present=bool(media.get('METADATA_BLOCK_PICTURE')) if path.suffix == '.opus' else bool(media.tags.get('covr')))
        scenario = self.scenario if info['id'] == 'first' else 'renamed'
        if scenario in ('start_failure', 'malformed_transport', 'internal_failure', 'raw_internal_failure'):
            event(self, info, 'infrastructure', error=scenario, rename_status='not_requested')
            if scenario == 'raw_internal_failure':
                raise RuntimeError('fixture unhandled internal bridge failure')
            raise PostProcessingError('fixture infrastructure ' + scenario)
        status = {'renamed': 'succeeded', 'unchanged': 'unchanged', 'rejected': 'rejected',
                  'failed_restored': 'failed', 'requires_attention': 'requires_attention',
                  'missing': 'requires_attention', 'not_requested': 'not_requested'}.get(scenario, 'succeeded')
        original = str(path)
        location = 'unknown' if scenario == 'requires_attention' else 'missing' if scenario == 'missing' else 'source'
        final = None if location in ('missing', 'unknown') else original
        if status == 'succeeded':
            location, final = 'destination', str(path.with_name('verified-fixture-' + path.name))
        result = {'rename_status': status, 'final_location': location, 'verified_final_path': final}
        projected = project_path(original, result)
        event(self, info, 'domain', **result, projected_filepath=projected,
              original_filepath=original, runtime_filepath=info['filepath'])
        # Result transport is a test event, not an ERROR line or permanent info field.
        return [], info


class FixtureAfterVideoPP(PostProcessor):
    def run(self, info):
        archive = Path(self.get_param('download_archive'))
        lines = archive.read_text(encoding='utf-8').splitlines() if archive.exists() else []
        private_clean = YoutubeDL.sanitize_info(dict(info), remove_private_keys=True)
        event(self, info, 'after_video', archive=lines,
              private_marker_serialized=SOURCE_METADATA_SUCCESS_KEY in json.dumps(private_clean),
              final_exists=Path(info['requested_downloads'][0]['filepath']).exists())
        return [], info


class LifecycleContractPP(PostProcessor):
    """Install probes once, through the real executable's plugin/PP API."""

    def __init__(self, downloader=None, scenario='renamed', version='2026.08.19'):
        super().__init__(downloader)
        if __version__ != version:
            raise PostProcessingError(f'yt-dlp version drift: expected {version}, found {__version__}; review lifecycle baseline')
        downstream = FixtureDownstreamPP(downloader, scenario)
        source = FixtureSourcePP(downloader, scenario)
        for pp in ([downstream, source] if scenario == 'reversed_order' else [source, downstream]):
            downloader.add_post_processor(pp, when='after_move')
        downloader.add_post_processor(FixtureAfterVideoPP(downloader), when='after_video')

    def run(self, info):
        if info['id'] == 'first' and self.get_param('outtmpl'):
            source_failure_checks(self, info)
            path_contract_checks(self, info)
        event(self, info, 'before_dl', version=__version__)
        return [], info
