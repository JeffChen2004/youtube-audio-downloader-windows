"""Offline executable lifecycle baseline, using only generated disposable media."""

from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from mutagen.mp4 import MP4
from mutagen.oggopus import OggOpus


ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / 'tools' / 'yt-dlp.exe'
EXPECTED_VERSION = '2026.08.19'
MARKER = '__yad_source_metadata_finalized_v1'


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


class LifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        version = subprocess.check_output([str(EXE), '--version'], text=True).strip()
        if version != EXPECTED_VERSION:
            raise AssertionError(f'yt-dlp version drift: {version} != {EXPECTED_VERSION}; review baseline before updating pin')
        cls.temp = tempfile.TemporaryDirectory(prefix='fixture-', dir=Path(__file__).parent)
        cls.root = Path(cls.temp.name)
        cls.media = cls.root / 'media'
        cls.media.mkdir()
        for ext, codec in [('opus', 'libopus'), ('m4a', 'aac'), ('webm', 'libopus')]:
            subprocess.run([str(ROOT / 'tools' / 'ffmpeg.exe'), '-hide_banner', '-loglevel', 'error',
                            '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.1', '-c:a', codec,
                            str(cls.media / f'tone.{ext}')], check=True, capture_output=True)
        # A generated thumbnail stays within the disposable fixture directory.
        subprocess.run([str(ROOT / 'tools' / 'ffmpeg.exe'), '-hide_banner', '-loglevel', 'error',
                        '-f', 'lavfi', '-i', 'color=c=red:s=16x16', '-frames:v', '1',
                        str(cls.media / 'cover.png')], check=True, capture_output=True)
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(cls.media)))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f'http://127.0.0.1:{cls.server.server_port}'
        cls.hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in cls.media.iterdir()}

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        assert cls.hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in cls.media.iterdir()}
        cls.temp.cleanup()

    def run_case(self, scenario, *, ignore=True, ext='opus', version=EXPECTED_VERSION):
        case = self.root / f'{scenario}-{ignore}-{ext}-{version}'
        case.mkdir()
        archive = case / 'archive.txt'
        command = [str(EXE), '--ignore-config', '--no-cache-dir', '--no-progress', '--no-simulate',
                   '--proxy', '', '--socket-timeout', '5', '--ffmpeg-location', str(ROOT / 'tools'),
                   '--no-plugin-dirs', '--plugin-dirs', str(ROOT / 'plugins'),
                   '--plugin-dirs', str(Path(__file__).parent.parent),
                   '--use-postprocessor', f'LifecycleContract:when=before_dl;scenario={scenario};version={version}',
                   '--embed-metadata', '--embed-thumbnail', '--write-info-json',
                   '--remux-video', 'webm>opus', '--download-archive', str(archive),
                   '--print', 'before_dl:__YAD_ITEM_START__%(.{id,playlist_index,playlist_count,n_entries,format_id})j',
                   '--print', 'after_video:__YAD_ITEM_SUCCESS__%(.{id,playlist_index,playlist_count,n_entries,format_id})j',
                   '--ignore-errors' if ignore else '--abort-on-error',
                   '-o', str(case / '%(id)s.%(ext)s'),
                   f'lifecyclefixture:{self.server.server_port}/{ext}']
        completed = subprocess.run(command, text=True, encoding='utf-8', errors='replace',
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45,
                                   env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        events = []
        for line in completed.stdout.splitlines():
            if '__YAD_LIFECYCLE__' in line:
                events.append(json.loads(line.split('__YAD_LIFECYCLE__', 1)[1]))
        lines = archive.read_text(encoding='utf-8').splitlines() if archive.exists() else []
        if version == EXPECTED_VERSION:
            log = case / 'child.log'
            log.write_text(completed.stdout, encoding='utf-8')
            accounting = subprocess.run(
                ['pwsh', '-NoLogo', '-NoProfile', '-File', str(Path(__file__).with_name('Accounting.Tests.ps1')),
                 '-RunLogPath', str(log), '-ChildExitCode', str(completed.returncode)],
                capture_output=True, text=True, encoding='utf-8', timeout=20)
            self.assertEqual(accounting.returncode, 0, accounting.stdout + accounting.stderr)
            report = json.loads(accounting.stdout.split('__YAD_ACCOUNTING__', 1)[1])
            expected_successes = completed.stdout.count('__YAD_ITEM_SUCCESS__')
            self.assertEqual(report['success_count'], expected_successes)
            self.assertEqual(report['failed_count'], 1 if not ignore or scenario in ('raw_internal_failure', 'raw_write_failure') else 0)
            self.assertEqual(report['current_tracker_success'], completed.returncode == 0)
            self.assertEqual(report['timestamp_success'], completed.returncode == 0)
            if completed.returncode:
                expected_job = 'failed'
            elif scenario in ('requires_attention', 'missing'):
                expected_job = 'requires_attention'
            elif scenario in ('rejected', 'failed_restored'):
                expected_job = 'completed_with_rename_errors'
            else:
                expected_job = 'completed'
            self.assertEqual(report['fixture_job_status'], expected_job)
            if scenario in ('rejected', 'failed_restored', 'requires_attention', 'missing'):
                expected = {'rejected': 'rejected', 'failed_restored': 'failed',
                            'requires_attention': 'requires_attention', 'missing': 'requires_attention'}[scenario]
                self.assertEqual(report['rename_status']['video:first'], expected)
        return completed, events, lines, case

    def assert_normal_tail(self, run, events, archive):
        self.assertEqual(archive, ['lifecyclefixture first', 'lifecyclefixture second'], run.stdout)
        self.assertEqual([e['id'] for e in events if e['phase'] == 'after_video'], ['first', 'second'])
        self.assertEqual(run.stdout.count('__YAD_ITEM_SUCCESS__'), 2)
        for index, tail in enumerate(e for e in events if e['phase'] == 'after_video'):
            self.assertEqual(tail['archive'], archive[:index + 1])
            self.assertFalse(tail['private_marker_serialized'])
            self.assertTrue(tail['final_exists'])
        for admission in (e for e in events if e['phase'] == 'admission' and e['admitted']):
            self.assertNotIn(f"lifecyclefixture {admission['id']}", admission['archive_before'])
            self.assertTrue(admission['cover_present'])
        checks = [e for e in events if e['phase'] == 'marker_check']
        self.assertEqual({e['case'] for e in checks}, {'invalid_media', 'raw_write_failure'})
        self.assertTrue(all(e['marker'] is False for e in checks))
        projection = next(e for e in events if e['phase'] == 'path_contract')
        self.assertTrue(projection['verified_path_used'])
        self.assertTrue(projection['impossible_claim_rejected'])

    def test_handled_domain_matrix(self):
        for scenario, status in [('renamed', 'succeeded'), ('unchanged', 'unchanged'),
                                 ('rejected', 'rejected'), ('failed_restored', 'failed'),
                                 ('requires_attention', 'requires_attention'), ('missing', 'requires_attention'),
                                 ('not_requested', 'not_requested')]:
            with self.subTest(scenario=scenario):
                run, events, archive, case = self.run_case(scenario)
                self.assertEqual(run.returncode, 0, run.stdout)
                self.assertNotIn('ERROR:', run.stdout)
                self.assert_normal_tail(run, events, archive)
                self.assertTrue(all(e['marker'] for e in events if e['phase'] == 'source'))
                domain = next(e for e in events if e['phase'] == 'domain' and e['id'] == 'first')
                self.assertEqual(domain['rename_status'], status)
                self.assertEqual(domain['runtime_filepath'], domain['original_filepath'])
                if status == 'succeeded':
                    self.assertEqual(domain['projected_filepath'], domain['verified_final_path'])
                    self.assertNotEqual(domain['projected_filepath'], domain['runtime_filepath'])
                    self.assertFalse(Path(domain['verified_final_path']).exists())
                else:
                    self.assertEqual(domain['projected_filepath'], domain['original_filepath'])
                if status == 'requires_attention':
                    self.assertIsNone(domain['verified_final_path'])
                self.assertEqual(next(e for e in events if e['id'] == 'second' and e['phase'] == 'domain')['rename_status'], 'succeeded')
                self.assert_private_outputs(case)

    def assert_private_outputs(self, case):
        for info in case.glob('*.info.json'):
            self.assertNotIn(MARKER, info.read_text(encoding='utf-8'))
        for path in case.glob('*.opus'):
            self.assertNotIn(MARKER.lower(), OggOpus(path).keys())
        for path in case.glob('*.m4a'):
            self.assertFalse(any(MARKER in key for key in MP4(path).tags))

    def test_upstream_and_admission_failures_under_ignore_errors(self):
        for scenario in ('write_failure', 'unsupported', 'invalid_media', 'reversed_order', 'bad_tags'):
            with self.subTest(scenario=scenario):
                run, events, archive, case = self.run_case(scenario)
                self.assertEqual(run.returncode, 1, run.stdout)
                self.assert_normal_tail(run, events, archive)
                first = [e for e in events if e['id'] == 'first']
                admission = next(e for e in first if e['phase'] == 'admission')
                self.assertFalse(admission['admitted'])
                self.assertFalse(admission['domain_entered'])
                self.assertFalse(any(e['phase'] == 'domain' for e in first))
                source = next(e for e in first if e['phase'] == 'source')
                self.assertEqual(source['marker'], scenario in ('reversed_order', 'bad_tags'))
                self.assertIn('ERROR:', run.stdout)
                self.assert_private_outputs(case)

    def test_infrastructure_errors_under_ignore_errors(self):
        for scenario in ('start_failure', 'malformed_transport', 'internal_failure'):
            with self.subTest(scenario=scenario):
                run, events, archive, _ = self.run_case(scenario)
                self.assertEqual(run.returncode, 1, run.stdout)
                self.assert_normal_tail(run, events, archive)
                self.assertEqual(next(e for e in events if e['phase'] == 'infrastructure')['error'], scenario)
                self.assertTrue(any(e['id'] == 'second' and e['phase'] == 'domain' for e in events))

    def test_abort_on_infrastructure_error(self):
        run, events, archive, _ = self.run_case('start_failure', ignore=False)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertEqual(archive, [])
        self.assertNotIn('__YAD_ITEM_SUCCESS__', run.stdout)
        self.assertFalse(any(e['id'] == 'second' for e in events))

    def test_raw_exceptions_skip_failed_item_but_not_playlist(self):
        for scenario in ('raw_internal_failure', 'raw_write_failure'):
            with self.subTest(scenario=scenario):
                run, events, archive, _ = self.run_case(scenario)
                self.assertEqual(run.returncode, 1, run.stdout)
                self.assertIn('ERROR: fixture', run.stdout)
                self.assertEqual(archive, ['lifecyclefixture second'])
                self.assertEqual([e['id'] for e in events if e['phase'] == 'after_video'], ['second'])
                self.assertEqual(run.stdout.count('__YAD_ITEM_SUCCESS__'), 1)
                self.assertTrue(any(e['id'] == 'second' and e['phase'] == 'domain' for e in events))
                if scenario == 'raw_write_failure':
                    self.assertFalse(next(e for e in events if e['id'] == 'first' and e['phase'] == 'source')['marker'])
                    self.assertFalse(any(e['id'] == 'first' and e['phase'] in ('admission', 'domain') for e in events))

    def test_m4a_and_webm_remux_marker(self):
        for ext in ('m4a', 'webm'):
            with self.subTest(ext=ext):
                run, events, archive, case = self.run_case('renamed', ext=ext)
                self.assertEqual(run.returncode, 0, run.stdout)
                self.assert_normal_tail(run, events, archive)
                self.assert_private_outputs(case)
                paths = [e['runtime_filepath'] for e in events if e['phase'] == 'domain']
                self.assertTrue(all(Path(p).suffix == ('.opus' if ext == 'webm' else '.m4a') for p in paths))

    def test_version_drift_is_explicit(self):
        run, _, archive, _ = self.run_case('renamed', version='0.0.fixture')
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('yt-dlp version drift', run.stdout)
        self.assertEqual(archive, [])


if __name__ == '__main__':
    unittest.main()
