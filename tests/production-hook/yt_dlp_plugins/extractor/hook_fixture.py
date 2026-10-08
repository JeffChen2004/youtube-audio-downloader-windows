from yt_dlp.extractor.common import InfoExtractor


class HookFixtureIE(InfoExtractor):
    _VALID_URL = r'hookfixture:(?P<port>\d+)/(?P<ext>opus|m4a|mp3|flac|wav)$'

    def _real_extract(self, url):
        match = self._match_valid_url(url)
        base = f'http://127.0.0.1:{match.group("port")}'
        ext = match.group('ext')
        entries = [{'id': item,'title': item,'extractor':'hookfixture','extractor_key':'HookFixture',
                    'webpage_url':f'{base}/{item}','url':f'{base}/tone.{ext}','ext':ext,
                    'format_id':'251','acodec':'opus' if ext=='opus' else 'aac','vcodec':'none',
                    'thumbnails':[{'id':'cover','url':f'{base}/cover.png'}]}
                   for item in ('first','second')]
        return self.playlist_result(entries,'hook-local','hook-local')
