"""Actual bundled yt-dlp + production hook + real managed adapter on fixtures."""

from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import json
import os
import ctypes
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


class HookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        version = subprocess.check_output([str(ROOT / 'tools/yt-dlp.exe'), '--version'], text=True).strip()
        if version != '2026.08.19':
            raise AssertionError('yt-dlp lifecycle baseline drift: ' + version)
        cls.temp = tempfile.TemporaryDirectory(prefix='hook-', dir=Path(__file__).parent)
        cls.root = Path(cls.temp.name)
        media = cls.root / 'media'
        media.mkdir()
        for ext, codec in [('opus','libopus'),('m4a','aac'),('mp3','libmp3lame'),('flac','flac'),('wav','pcm_s16le')]:
            subprocess.run([str(ROOT / 'tools/ffmpeg.exe'), '-hide_banner','-loglevel','error',
                            '-f','lavfi','-i','sine=duration=0.1','-c:a',codec,str(media / f'tone.{ext}')],
                           check=True, capture_output=True)
        subprocess.run([str(ROOT / 'tools/ffmpeg.exe'),'-hide_banner','-loglevel','error',
                        '-f','lavfi','-i','color=c=red:s=16x16','-frames:v','1',str(media / 'cover.png')],
                       check=True, capture_output=True)
        cls.server = ThreadingHTTPServer(('127.0.0.1',0),partial(QuietHandler,directory=str(media)))
        cls.thread = threading.Thread(target=cls.server.serve_forever,daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temp.cleanup()

    def run_case(self, scenario, ext='opus', direct=False, safety=False):
        case = self.root / f'{scenario}-{ext}'
        case.mkdir()
        command = [str(ROOT / 'tools/yt-dlp.exe'),'--ignore-config','--no-cache-dir','--no-progress','--no-simulate',
                   '--proxy','','--no-plugin-dirs','--plugin-dirs',str(ROOT / 'plugins'),
                   '--plugin-dirs',str(ROOT / 'tests'),'--ffmpeg-location',str(ROOT / 'tools'),
                   '--ignore-errors','--embed-metadata','--write-info-json',
                   '--use-postprocessor',f'ProductionHookFixture:when=before_dl;scenario={scenario}',
                   '--download-archive',str(case / 'archive.txt'),
                   '--print','before_dl:__YAD_ITEM_START__%(.{id,playlist_index,playlist_count,n_entries,format_id})j',
                   '--print','after_video:__YAD_ITEM_SUCCESS__%(.{id,playlist_index,playlist_count,n_entries,format_id})j',
                   '-o',str(case / '%(id)s.%(ext)s')]
        if ext != 'wav':
            command += ['--embed-thumbnail']
        if direct:
            command += ['--use-postprocessor','SourceMetadataPrepare:when=video;client=fixture',
                        '--use-postprocessor','SourceMetadata:when=after_move;client=fixture',
                        '--use-postprocessor','MusicRenamer:when=after_move']
        command += [f'hookfixture:{self.server.server_port}/{ext}']
        env = {**os.environ, 'PYTHONDONTWRITEBYTECODE':'1'}
        if direct:
            env['YAD_MUSIC_RENAMER_CONFIG'] = json.dumps({'template':'Direct-{youtube_id}', 'warning_acknowledged':False,
                'artist_aliases':[], 'title_cleanup_rules':[], 'extraction':{'artist_quoted_title':False,'title_slash_artist':False}})
        if safety:
            command_file=case / 'command.json'
            command_file.write_text(json.dumps(command),encoding='utf-8')
            parent=subprocess.run(['pwsh','-NoLogo','-NoProfile','-File',str(ROOT / 'tests/production-hook/Cancellation.Tests.ps1'),
                                  '-CommandPath',str(command_file),'-ControlRoot',str(case),'-Scenario',scenario],
                                 capture_output=True,text=True,encoding='utf-8',timeout=70,env=env)
            self.assertEqual(parent.returncode,0,parent.stdout+parent.stderr)
            report=json.loads(parent.stdout.split('__CANCEL_REPORT__',1)[1])
            output=(case/'stdout.log').read_text(encoding='utf-8')+(case/'stderr.log').read_text(encoding='utf-8')
            return report,output,case
        run = subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,
                             encoding='utf-8',errors='replace',timeout=70,env=env)
        events, probes = [], []
        for line in run.stdout.splitlines():
            if line.startswith('__YAD_RENAME_RESULT__'):
                events.append(json.loads(line[len('__YAD_RENAME_RESULT__'):]))
            if line.startswith('__HOOK_PROBE__'):
                probes.append(json.loads(line[len('__HOOK_PROBE__'):]))
        log = case / 'child.log'
        log.write_text(run.stdout, encoding='utf-8')
        replay = subprocess.run(['pwsh','-NoLogo','-NoProfile','-File',str(ROOT / 'tests/lifecycle/Accounting.Tests.ps1'),
                                 '-RunLogPath',str(log),'-ChildExitCode',str(run.returncode)],
                                capture_output=True,text=True,encoding='utf-8',timeout=20)
        self.assertEqual(replay.returncode,0,replay.stdout+replay.stderr)
        report = json.loads(replay.stdout.split('__YAD_ACCOUNTING__',1)[1])
        partial = any(e['rename_status'] in ('rejected','failed','requires_attention') for e in events)
        self.assertEqual(report['production_job_status'],'failed' if run.returncode else 'completed_with_rename_errors' if partial else 'completed')
        self.assertEqual(report['production_download_success'],run.returncode==0)
        self.assertEqual(report['success_count'],2)
        self.assertEqual(report['failed_count'],0)
        self.assertEqual(report['current_tracker_success'],run.returncode==0 and not partial)
        self.assertEqual(len(report['production_rename_results']),len(events))
        return run, events, probes, case

    def test_handled_outcomes_and_stale_path_admission(self):
        for scenario, expected in [('unchanged','unchanged'),('rejected','rejected'),('failed','failed'),
                                   ('unknown','requires_attention'),('missing','requires_attention')]:
            with self.subTest(scenario=scenario):
                run, events, probes, _ = self.run_case(scenario)
                self.assertEqual(run.returncode,0,run.stdout)
                self.assertNotIn('ERROR:',run.stdout)
                self.assertEqual([e['rename_status'] for e in events],[expected,'unchanged'])
                first = next(p for p in probes if p['stage']=='after_bridge' and p['id']=='first')
                self.assertTrue(first['integrity'])
                if expected=='requires_attention':
                    self.assertEqual(first['state']['path_validity'],'unverified')
                    self.assertTrue(first['stale_retained'])
                    self.assertIsNone(first['consumer_path'])
                self.assertEqual(next(p for p in probes if p['stage']=='after_video' and p['id']=='second')['archive'],
                                 ['hookfixture first','hookfixture second'])
                for p in probes:
                    if p['stage']=='invoke':
                        self.assertEqual(p['config']['template'],'Hook-{youtube_id}')
                    if p['stage']=='after_video':
                        self.assertFalse(p['private_serialized'])

    def test_infrastructure_and_admission_fail_closed(self):
        for scenario, code in [('no_marker','source_metadata_not_finalized'),('bad_tags','final_tags_invalid'),
                               ('infrastructure','adapter_timeout'),('unexpected','unexpected_bridge_failure'),
                               ('outer_timeout','adapter_timeout'),
                               ('correlation','correlation_mismatch'),('protocol','protocol_mismatch'),
                               ('contradictory','invalid_final_path'),('malformed','malformed_transport')]:
            with self.subTest(scenario=scenario):
                run, events, probes, _ = self.run_case(scenario)
                self.assertEqual(run.returncode,1,run.stdout)
                self.assertEqual(events[0]['rename_status'],'infrastructure_failed')
                self.assertEqual(events[0]['issue_code'],code)
                self.assertEqual(events[1]['rename_status'],'unchanged')
                self.assertTrue(next(p for p in probes if p['stage']=='after_bridge' and p['id']=='first')['integrity'])
                self.assertEqual(len([p for p in probes if p['stage']=='after_video']),2)
                if scenario in ('no_marker','bad_tags'):
                    self.assertFalse(any(p['stage']=='invoke' and p['id']=='first' for p in probes))
                if scenario == 'outer_timeout':
                    pid = next(p for p in probes if p['stage']=='after_bridge' and p['id']=='first')['overrun_pid']
                    self.assertIsNotNone(pid)
                    kernel = ctypes.WinDLL('kernel32',use_last_error=True)
                    kernel.OpenProcess.restype = ctypes.c_void_p
                    kernel.OpenProcess.argtypes = [ctypes.c_uint32,ctypes.c_int,ctypes.c_uint32]
                    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
                    handle = kernel.OpenProcess(0x1000,False,pid)
                    if handle:
                        code = ctypes.c_uint32()
                        kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint32)]
                        self.assertTrue(kernel.GetExitCodeProcess(handle,ctypes.byref(code)))
                        kernel.CloseHandle(handle)
                        self.assertNotEqual(code.value,259,'overrun must not leave an adapter child running')

    def test_disabled_and_unsupported(self):
        run, events, probes, _ = self.run_case('disabled')
        self.assertEqual(run.returncode,0,run.stdout)
        self.assertEqual(events,[])
        self.assertFalse(any(p['stage']=='invoke' for p in probes))
        for ext in ('mp3','flac','wav'):
            with self.subTest(ext=ext):
                run, events, probes, _ = self.run_case('unsupported',ext)
                self.assertEqual(run.returncode,0,run.stdout)
                self.assertEqual([e['rename_status'] for e in events],['unsupported','unsupported'])
                self.assertFalse(any(p['stage']=='invoke' for p in probes))

    def test_real_adapter_rename_reject_warning_and_integrity(self):
        for scenario in ('real_renamed','real_rejected','real_warning'):
            for ext in ('opus','m4a'):
                with self.subTest(scenario=scenario,ext=ext):
                    run, events, probes, case = self.run_case(scenario,ext)
                    self.assertEqual(run.returncode,0,run.stdout)
                    expected = 'succeeded' if scenario=='real_renamed' else 'rejected'
                    self.assertEqual([e['rename_status'] for e in events],[expected,expected])
                    for p in probes:
                        if p['stage']=='after_bridge':
                            # Exact whole-file SHA256 equality proves audio,
                            # tags and cover remain bit-for-bit unchanged.
                            self.assertTrue(p['integrity'])
                            self.assertEqual(Path(p['consumer_path']).suffix,'.'+ext)
                            if expected=='succeeded':
                                self.assertEqual(Path(p['consumer_path']).name,f"Hook-{p['id']}.{ext}")
                                self.assertFalse(p['stale_retained'])
                    for infojson in case.glob('*.info.json'):
                        self.assertNotIn('__yad_music_renamer', infojson.read_text(encoding='utf-8'))

    def test_real_production_registration(self):
        run, events, _, case = self.run_case('real_direct_registration',direct=True)
        self.assertEqual(run.returncode,0,run.stdout)
        self.assertEqual([e['rename_status'] for e in events],['succeeded','succeeded'])
        self.assertTrue((case / 'Direct-first.opus').is_file())
        self.assertTrue((case / 'Direct-second.opus').is_file())

    def test_cancellation_safety_real_core(self):
        for scenario,outcome in [('cancel_before','cancelled'),('cancel_planning','cancelled'),('cancel_preflight','cancelled'),
                                 ('cancel_success','succeeded'),('cancel_rollback','failed'),
                                 ('cancel_incomplete','requires_attention'),('timeout_execution','succeeded'),
                                 ('outer_timeout_execution','succeeded'),('cancel_crash','infrastructure_failed'),
                                 ('crash_execution','infrastructure_failed')]:
            with self.subTest(scenario=scenario):
                report,output,case=self.run_case(scenario,safety=True)
                events=[json.loads(line[len('__YAD_RENAME_RESULT__'):]) for line in output.splitlines() if line.startswith('__YAD_RENAME_RESULT__')]
                self.assertEqual(events[0]['rename_status'],outcome,output)
                if scenario.startswith('cancel_'):
                    self.assertEqual(report['status'],'cancelled')
                    self.assertTrue(events[0]['cancel_requested'])
                    self.assertEqual(len(events),1,'no next item rename after cancellation')
                    self.assertFalse((case/'second.opus').exists(),'playlist must stop before second item')
                if outcome=='cancelled':
                    self.assertFalse(events[0]['mutation_started'])
                    self.assertTrue((case/'first.opus').is_file())
                    self.assertFalse((case/'Hook-first.opus').exists())
                    self.assertFalse(any(p.name.startswith('.music-renamer') for p in case.iterdir()))
                if outcome in ('succeeded','failed'):
                    self.assertTrue(events[0]['mutation_started'])
                    self.assertEqual(events[0]['path_validity'],'verified')
                    self.assertEqual(events[0]['recovery_status'],'succeeded' if outcome=='succeeded' else 'failed_rolled_back')
                if outcome=='requires_attention':
                    self.assertTrue(report['requires_attention'])
                    self.assertEqual(events[0]['recovery_status'],'failed_rollback_incomplete')
                if outcome=='infrastructure_failed':
                    self.assertTrue(events[0]['requires_attention'])
                    self.assertIsNone(events[0]['verified_final_path'])
                if scenario in ('timeout_execution','outer_timeout_execution'):
                    self.assertEqual(report['status'],'completed')
                    self.assertIn('timeout deferred',output)


if __name__=='__main__':
    unittest.main()
