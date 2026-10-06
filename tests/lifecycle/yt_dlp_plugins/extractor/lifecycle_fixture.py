"""Controlled two-item playlist; only loopback URLs are constructible."""

from yt_dlp.extractor.common import InfoExtractor


class LifecycleFixtureIE(InfoExtractor):
    _VALID_URL = r'lifecyclefixture:(?P<port>\d+)/(?P<ext>opus|m4a|webm)$'

    def _real_extract(self, url):
        match = self._match_valid_url(url)
        base = f'http://127.0.0.1:{match.group("port")}'
        ext = match.group('ext')
        entries = [{'id': item, 'title': item, 'extractor': 'lifecyclefixture',
                    'extractor_key': 'LifecycleFixture', 'webpage_url': f'{base}/{item}',
                    'url': f'{base}/tone.{ext}', 'ext': ext, 'format_id': '251',
                    'acodec': 'aac' if ext == 'm4a' else 'opus', 'vcodec': 'none',
                    'thumbnails': [{'url': f'{base}/cover.png', 'id': 'cover'}]}
                   for item in ('first', 'second')]
        return self.playlist_result(entries, playlist_id='local', playlist_title='local')
