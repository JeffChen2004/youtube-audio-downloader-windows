"""Non-mutating settings validation through the real managed adapter contract."""
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ConfigValidationTests(unittest.TestCase):
    def invoke(self, config, operation='validate_config'):
        request = dict(protocol_version=1, correlation_id='config-test', operation=operation, config=config)
        run = subprocess.run([sys.executable, '-B', str(ROOT / 'integrations/music-renamer/adapter.py'),
                              '--manifest', str(ROOT / 'tools/music-renamer-runtime/integration-manifest.json')],
                             input=json.dumps(request), text=True, capture_output=True, timeout=30)
        self.assertEqual(len(run.stdout.splitlines()), 1)
        response = json.loads(run.stdout)
        self.assertEqual(response['correlation_id'], 'config-test')
        self.assertEqual(response['protocol_version'], 1)
        return run, response

    def config(self):
        return dict(template='{artist} - {title} [{youtube_id}]', warning_acknowledged=False,
                    artist_aliases=[], title_cleanup_rules=[],
                    extraction=dict(artist_quoted_title=False, title_slash_artist=False))

    def test_valid_config_needs_no_media_and_has_no_execution(self):
        run, result = self.invoke(self.config())
        self.assertEqual(run.returncode, 0)
        self.assertEqual(run.stderr, '')
        self.assertTrue(result['valid'])
        self.assertEqual(result['issues'], [])
        self.assertIsNone(result['error'])
        self.assertNotIn('execution', result)

    def test_semantic_rejections_are_normal_json_not_infrastructure_exits(self):
        for field, value, code in [('template', '{unknown}', 'unknown_placeholder'),
                                   ('artist_aliases', [dict(source='', target='x')], 'invalid_config'),
                                   ('title_cleanup_rules', [dict(kind='new_pattern', text='x')], 'invalid_config')]:
            with self.subTest(field=field):
                config = self.config()
                config[field] = value
                run, result = self.invoke(config)
                self.assertEqual(run.returncode, 0)
                self.assertEqual(run.stderr, '')
                self.assertFalse(result['valid'])
                self.assertIn(code, [issue['code'] for issue in result['issues']])
                self.assertNotIn('execution', result)

    def test_alias_cleanup_and_existing_extraction_rules_use_core_validation(self):
        config = self.config()
        config.update(artist_aliases=[dict(source='Fixture', target='Canonical')],
                      title_cleanup_rules=[dict(kind='remove_suffix', text=' (official)')],
                      extraction=dict(artist_quoted_title=True, title_slash_artist=True))
        run, result = self.invoke(config)
        self.assertEqual(run.returncode, 0)
        self.assertTrue(result['valid'])
        config['artist_aliases'].append(dict(source='Fixture', target='Different'))
        run, result = self.invoke(config)
        self.assertEqual(run.returncode, 0)
        self.assertFalse(result['valid'])

    def test_unsupported_operation_remains_infrastructure_failure(self):
        run, result = self.invoke(self.config(), 'unknown')
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(result['error']['code'], 'unsupported_operation')


if __name__ == '__main__':
    unittest.main()
