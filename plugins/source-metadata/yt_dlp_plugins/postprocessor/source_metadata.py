from __future__ import annotations

from datetime import datetime
from pathlib import Path

from yt_dlp.dependencies import mutagen
from yt_dlp.postprocessor.common import PostProcessor
from yt_dlp.utils import PostProcessingError

if mutagen:
    from mutagen.flac import FLAC
    from mutagen.id3 import TXXX
    from mutagen.mp3 import MP3
    from mutagen.mp4 import MP4, MP4FreeForm
    from mutagen.oggopus import OggOpus
    from mutagen.wave import WAVE


# Process-local admission signal, not an embedded tag or public metadata field.
# yt-dlp's clean info serialization removes double-underscore private keys.
SOURCE_METADATA_SUCCESS_KEY = '__yad_source_metadata_finalized_v1'


class SourceMetadataPP(PostProcessor):
    """Persist the exact selected YouTube audio format in the output file."""

    def __init__(self, downloader=None, client='Auto', preserve='false'):
        super().__init__(downloader)
        self._client = client or 'Unknown'
        self._preserve = str(preserve).lower() in ('1', 'true', 'yes')

    @staticmethod
    def _selected_audio(info):
        def find_audio(candidates):
            for candidate in candidates or []:
                nested = candidate.get('requested_formats') or []
                selected = find_audio(nested)
                if selected:
                    return selected
                if candidate.get('acodec') not in (None, 'none'):
                    return candidate
            return None

        selected = find_audio(info.get('requested_downloads'))
        if selected:
            return selected
        selected = find_audio(info.get('requested_formats'))
        if selected:
            return selected
        return info

    @staticmethod
    def _codec_name(value):
        codec = str(value or '').strip()
        lowered = codec.lower()
        if 'opus' in lowered:
            return 'opus'
        if lowered == 'aac' or lowered.startswith('mp4a'):
            return 'aac'
        return codec

    @staticmethod
    def _abr_value(value):
        if value in (None, ''):
            return ''
        try:
            return f'{float(value):.3f}'.rstrip('0').rstrip('.')
        except (TypeError, ValueError):
            return str(value)

    @staticmethod
    def _quality(format_id):
        return {
            '774': 'Premium Opus',
            '141': 'Premium AAC',
            '251': 'Standard Opus',
        }.get(format_id, 'Fallback')

    @staticmethod
    def _merge_comment(existing, source_line):
        def render(value):
            if isinstance(value, bytes):
                return value.decode('utf-8', errors='replace')
            return str(value)

        values = existing if isinstance(existing, (list, tuple)) else [existing]
        text = '\n'.join(render(value) for value in values if value)
        if source_line in text:
            return text
        return f'{text}\n{source_line}' if text else source_line

    @staticmethod
    def _standard_tags(info):
        def text(value):
            if isinstance(value, (list, tuple)):
                return ', '.join(str(item) for item in value if item)
            return str(value or '').strip()

        artist = next((text(info.get(key)) for key in (
            'artist', 'artists', 'creator', 'creators', 'uploader', 'channel')
            if text(info.get(key))), '')
        date = text(info.get('release_date') or info.get('upload_date') or info.get('release_year'))
        return {
            'title': text(info.get('track') or info.get('title')),
            'artist': artist,
            'album': text(info.get('album')),
            'track': text(info.get('track_number')),
            'date': date,
        }

    @staticmethod
    def _write_opus(path, tags, standard):
        media = OggOpus(path)
        for key, value in tags.items():
            media[key] = [value]
        mapping = {'title': 'TITLE', 'artist': 'ARTIST', 'album': 'ALBUM', 'track': 'TRACKNUMBER', 'date': 'DATE'}
        for field, key in mapping.items():
            if standard[field]:
                media[key] = [standard[field]]
        has_cover = bool(media.get('METADATA_BLOCK_PICTURE'))
        media.save()
        return has_cover

    @staticmethod
    def _write_m4a(path, tags, standard):
        media = MP4(path)
        if media.tags is None:
            media.add_tags()
        for key, value in tags.items():
            atom = f'----:com.apple.iTunes:{key}'
            media.tags[atom] = [MP4FreeForm(value.encode('utf-8'))]
        standard_atoms = {'title': '\xa9nam', 'artist': '\xa9ART', 'album': '\xa9alb', 'date': '\xa9day'}
        for field, atom in standard_atoms.items():
            if standard[field]:
                media.tags[atom] = [standard[field]]
        if standard['track']:
            try:
                media.tags['trkn'] = [(int(standard['track']), 0)]
            except ValueError:
                pass
        has_cover = bool(media.tags.get('covr'))
        media.save()
        return has_cover

    @staticmethod
    def _write_flac(path, tags, standard):
        media = FLAC(path)
        for key, value in tags.items():
            media[key] = [value]
        mapping = {'title': 'TITLE', 'artist': 'ARTIST', 'album': 'ALBUM', 'track': 'TRACKNUMBER', 'date': 'DATE'}
        for field, key in mapping.items():
            if standard[field]:
                media[key] = [standard[field]]
        has_cover = bool(media.pictures)
        media.save()
        return has_cover

    @staticmethod
    def _write_mp3(path, tags):
        media = MP3(path)
        if media.tags is None:
            media.add_tags()
        for key, value in tags.items():
            media.tags.delall(f'TXXX:{key}')
            media.tags.add(TXXX(encoding=3, desc=key, text=[value]))
        has_cover = bool(media.tags.getall('APIC'))
        media.save(v2_version=3)
        return has_cover

    @staticmethod
    def _write_wave(path, tags):
        media = WAVE(path)
        if media.tags is None:
            media.add_tags()
        for key, value in tags.items():
            media.tags.delall(f'TXXX:{key}')
            media.tags.add(TXXX(encoding=3, desc=key, text=[value]))
        has_cover = bool(media.tags.getall('APIC'))
        media.save(v2_version=3)
        return has_cover

    def _source_details(self, info):
        selected = self._selected_audio(info)
        format_id = str(selected.get('format_id') or info.get('format_id') or '').strip()
        codec = self._codec_name(selected.get('acodec') or info.get('acodec'))
        abr = self._abr_value(selected.get('abr') if selected.get('abr') is not None else info.get('abr'))
        source_url = str(info.get('webpage_url') or info.get('original_url') or '').strip()
        youtube_id = str(info.get('id') or '').strip()
        quality = self._quality(format_id)
        standard = self._standard_tags(info)
        tags = {
            'SOURCE_FORMAT_ID': format_id,
            'SOURCE_CODEC': codec,
            'SOURCE_ABR': abr,
            'SOURCE_CLIENT': self._client,
            'SOURCE_QUALITY': quality,
            'YOUTUBE_ID': youtube_id,
            'SOURCE_URL': source_url,
            'DOWNLOAD_DATE': datetime.now().astimezone().date().isoformat(),
        }
        playlist_title = str(info.get('playlist_title') or info.get('playlist') or '').strip()
        playlist_index = info.get('playlist_index')
        playlist_id = str(info.get('playlist_id') or '').strip()
        if playlist_title:
            tags['PLAYLIST_TITLE'] = playlist_title
        if playlist_index not in (None, ''):
            tags['PLAYLIST_INDEX'] = str(playlist_index)
        if playlist_id:
            tags['PLAYLIST_ID'] = playlist_id
        abr_display = f'{abr} kbps' if abr else 'Unknown'
        source_line = (
            f'Source: YouTube | Format: {format_id or "Unknown"} | '
            f'Codec: {codec or "Unknown"} | ABR: {abr_display} | Client: {self._client}'
        )
        return tags, standard, source_line, format_id, codec, abr_display

    def run(self, info):
        # A reused info dictionary must not retain success from an earlier run.
        info.pop(SOURCE_METADATA_SUCCESS_KEY, None)
        if not mutagen:
            raise PostProcessingError('yt-dlp build does not include mutagen; source metadata was not written')

        tags, standard, source_line, format_id, codec, abr_display = self._source_details(info)

        path = info.get('filepath')
        if not path or not Path(path).is_file():
            raise PostProcessingError('final media file was not found for source metadata tagging')
        ext = str(info.get('ext') or Path(path).suffix.lstrip('.')).lower()
        if ext == 'opus':
            has_cover = self._write_opus(path, tags, standard)
        elif ext in ('m4a', 'mp4', 'mov'):
            has_cover = self._write_m4a(path, tags, standard)
        elif ext == 'flac':
            has_cover = self._write_flac(path, tags, standard)
        elif ext == 'mp3':
            has_cover = self._write_mp3(path, tags)
        elif ext == 'wav':
            has_cover = self._write_wave(path, tags)
        else:
            raise PostProcessingError(f'custom source metadata is not supported for .{ext}')

        self.to_screen('[Metadata] Title/artist metadata and source tags embedded')
        self.to_screen('[Thumbnail] Cover embedded' if has_cover else '[Thumbnail] Cover unavailable')
        self.to_screen(
            f'[Source] format={format_id or "Unknown"}; codec={codec or "Unknown"}; '
            f'abr={abr_display}; client={self._client}')
        if self._preserve:
            self.to_screen(f'[Output] .{ext}; audio stream copied without re-encoding')
        else:
            self.to_screen(f'[Output] .{ext}; metadata tagging added no further audio re-encoding')
        info[SOURCE_METADATA_SUCCESS_KEY] = True
        return [], info


class SourceMetadataPreparePP(SourceMetadataPP):
    """Prepare actual selected-format fields before yt-dlp embeds metadata."""

    def run(self, info):
        tags, _standard, source_line, _format_id, _codec, _abr_display = self._source_details(info)
        for key, value in tags.items():
            info[f'meta_{key}'] = value
        existing_comment = (
            info.get('meta_comment')
            or info.get('comment')
            or info.get('webpage_url')
            or info.get('original_url')
        )
        info['meta_comment'] = self._merge_comment(existing_comment, source_line)
        return [], info
