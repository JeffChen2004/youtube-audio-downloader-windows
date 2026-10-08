"""Controlled production bridge probes, never loaded by Downloader startup."""

import hashlib
import json
import os
from pathlib import Path

from yt_dlp.dependencies import mutagen
from yt_dlp.postprocessor.common import PostProcessor
from yt_dlp_plugins.postprocessor.source_metadata import SourceMetadataPP, SOURCE_METADATA_SUCCESS_KEY
from yt_dlp_plugins.postprocessor.music_renamer import (
    MusicRenamerPP, RESULT_KEY, CONFIG_ENV, IntegrationFailure, verified_music_renamer_path,
)
import yt_dlp_plugins.postprocessor.music_renamer as bridge_module

__all__ = ['ProductionHookFixturePP']


def probe(pp, info, stage, **fields):
    pp._downloader.to_stdout('__HOOK_PROBE__' + json.dumps({'id': info['id'], 'stage': stage, **fields}, separators=(',', ':')))


class FixtureBridge(MusicRenamerPP):
    def __init__(self, downloader, scenario):
        super().__init__(downloader, enabled='false' if scenario == 'disabled' else 'true')
        self.scenario = scenario

    def _invoke_adapter(self, request):
        scenario = self.scenario if self.scenario.startswith('real_') or request['source_path'].endswith('first.opus') else 'unchanged'
        if scenario.startswith('cancel_') or scenario in ('timeout_execution','outer_timeout_execution','crash_execution'):
            previous=bridge_module.LAUNCHER
            bridge_module.LAUNCHER=bridge_module.ROOT / 'tests/production-hook/cancellation-launcher.ps1'
            if scenario in ('timeout_execution','outer_timeout_execution'):
                self._timeout=1
            try:
                return super()._invoke_adapter(request)
            finally:
                bridge_module.LAUNCHER=previous
        if scenario.startswith('real_'):
            return super()._invoke_adapter(request)
        if scenario == 'outer_timeout':
            # Exercise the production launcher's overrun/tree cleanup branch.
            parent = Path(request['source_path']).parent
            pid_file = parent / 'overrun.pid'
            adapter = parent / 'sleep.py'
            adapter.write_text('import os,time\nfrom pathlib import Path\n'
                               + f'Path({str(pid_file)!r}).write_text(str(os.getpid()))\n'
                               + 'time.sleep(60)\n', encoding='utf-8')
            shell = parent / 'overrun.ps1'
            runtime = bridge_module.ROOT / 'tools/music-renamer-runtime/python.exe'
            quote = lambda value: "'" + str(value).replace("'", "''") + "'"
            shell.write_text('param([int]$TimeoutSeconds)\n& ' + quote(runtime) + ' ' + quote(adapter), encoding='utf-8-sig')
            previous, timeout = bridge_module.LAUNCHER, self._timeout
            bridge_module.LAUNCHER, self._timeout = shell, 1
            try:
                return super()._invoke_adapter(request)
            finally:
                bridge_module.LAUNCHER, self._timeout = previous, timeout
        if scenario == 'unexpected':
            raise RuntimeError('fixture unexpected bug')
        if scenario == 'infrastructure':
            raise IntegrationFailure('adapter_timeout')
        original = request['source_path']
        status = {'rejected': 'rejected', 'failed': 'failed', 'unknown': 'requires_attention',
                  'missing': 'requires_attention'}.get(scenario, 'unchanged')
        outcome = {'unchanged': 'no_op', 'failed': 'failed_rolled_back',
                   'requires_attention': 'failed_rollback_incomplete'}.get(status)
        location = 'unknown' if scenario == 'unknown' else 'missing' if scenario == 'missing' else 'source'
        final = None if status == 'requires_attention' else original
        execution = None if status == 'rejected' else {'transaction_id': 'fixture', 'plan_id': 'fixture',
            'outcome': outcome, 'preflight_issues': [], 'operations': [{'item_id': 'fixture',
            'source_path': original, 'final_path': final, 'final_location': location}]}
        result = {'protocol_version': 1, 'correlation_id': request['correlation_id'], 'operation': 'rename',
                  'adapter_status': 'completed', 'classification': status,
                  'path': {'original_path': original, 'verified_final_path': final if execution else None,
                           'destination_path': None, 'final_location': location if execution else None},
                  'execution': execution, 'planning': {'issue_codes': []},
                  'rejection_reason': 'fixture_rejected' if status == 'rejected' else None, 'error': None}
        if scenario == 'correlation':
            result['correlation_id'] = 'other'
        if scenario == 'protocol':
            result['protocol_version'] = 99
        if scenario == 'contradictory':
            result['classification'] = 'requires_attention'
            result['execution']['outcome'] = 'failed_rollback_incomplete'
            result['path']['final_location'] = 'unknown'
        if scenario == 'malformed':
            return ['not an object']
        probe(self, {'id': Path(original).stem}, 'invoke', config=request['config'])
        return result

    def run(self, info):
        if info['id'] == 'first':
            if self.scenario == 'no_marker':
                info.pop(SOURCE_METADATA_SUCCESS_KEY, None)
            if self.scenario == 'bad_tags':
                # Tamper only with a generated fixture's provenance tag.
                media = mutagen.File(info['filepath'])
                del media['YOUTUBE_ID']
                media.save()
        path = Path(info['filepath'])
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        try:
            return super().run(info)
        finally:
            verified = verified_music_renamer_path(info)
            unchanged_runtime = info['filepath'] == str(path)
            if verified is not None:
                intact = before == hashlib.sha256(verified.read_bytes()).hexdigest()
            else:
                intact = path.exists() and before == hashlib.sha256(path.read_bytes()).hexdigest()
            probe(self, info, 'after_bridge', state=info.get(RESULT_KEY),
                  runtime_filepath=info['filepath'], consumer_path=str(verified) if verified else None,
                  stale_retained=unchanged_runtime, integrity=intact,
                  overrun_pid=int((path.parent / 'overrun.pid').read_text()) if (path.parent / 'overrun.pid').exists() else None)


class AfterHookPP(PostProcessor):
    def run(self, info):
        entry = info['requested_downloads'][0]
        state = entry.get(RESULT_KEY)
        archive = Path(self.get_param('download_archive')).read_text(encoding='utf-8').splitlines()
        probe(self, info, 'after_video', archive=archive, state=state,
              private_serialized=RESULT_KEY in json.dumps(self._downloader.sanitize_info(dict(info), remove_private_keys=True)))
        return [], info


class ProductionHookFixturePP(PostProcessor):
    def __init__(self, downloader=None, scenario='unchanged'):
        super().__init__(downloader)
        self.scenario = scenario
        if scenario == 'real_direct_registration':
            downloader.add_post_processor(AfterHookPP(downloader), when='after_video')
            return
        config = {'template': 'Hook-{youtube_id}', 'warning_acknowledged': False,
                  'artist_aliases': [], 'title_cleanup_rules': [],
                  'extraction': {'artist_quoted_title': False, 'title_slash_artist': False}}
        if scenario == 'real_rejected':
            config['template'] = '{performer}'
        if scenario == 'real_warning':
            config['template'] = '{title}?'
        os.environ[CONFIG_ENV] = json.dumps(config)
        self.bridge = FixtureBridge(downloader, scenario)
        # Changing env after capture must never change the operation snapshot.
        os.environ[CONFIG_ENV] = '{}'
        downloader.add_post_processor(SourceMetadataPP(downloader, client='fixture'), when='after_move')
        downloader.add_post_processor(self.bridge, when='after_move')
        downloader.add_post_processor(AfterHookPP(downloader), when='after_video')

    def run(self, info):
        return [], info
