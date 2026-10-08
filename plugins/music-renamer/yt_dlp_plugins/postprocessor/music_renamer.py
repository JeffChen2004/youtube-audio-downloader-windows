"""Thin opt-in post-download bridge to Downloader's managed Core adapter."""

import json
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from uuid import uuid4

from yt_dlp.dependencies import mutagen
from yt_dlp.postprocessor.common import PostProcessor
from yt_dlp.utils import PostProcessingError, DownloadCancelled
from yt_dlp_plugins.postprocessor.source_metadata import SOURCE_METADATA_SUCCESS_KEY

__all__ = ['MusicRenamerPP']

CONFIG_ENV = 'YAD_MUSIC_RENAMER_CONFIG'
RESULT_KEY = '__yad_music_renamer_result_v1'
EVENT_PREFIX = '__YAD_RENAME_RESULT__'
ROOT = Path(__file__).resolve().parents[4]
LAUNCHER = ROOT / 'integrations' / 'music-renamer' / 'Invoke-MusicRenamerRename.ps1'
SYSTEM_ROOT = Path(os.environ.get('SystemRoot', 'C:/Windows'))
POWERSHELL = SYSTEM_ROOT / 'System32' / 'WindowsPowerShell' / 'v1.0' / 'powershell.exe'
TASKKILL = SYSTEM_ROOT / 'System32' / 'taskkill.exe'
_spec = importlib.util.spec_from_file_location('renamer_cancellation', ROOT / 'integrations/music-renamer/cancellation.py')
_safety = importlib.util.module_from_spec(_spec)
_safety_bytecode = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    _spec.loader.exec_module(_safety)
finally:
    sys.dont_write_bytecode = _safety_bytecode
JOB_GATE_ENV = 'YAD_RENAMER_GATE'
JOB_CANCEL_ENV = 'YAD_RENAMER_CANCEL'


class IntegrationFailure(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def verified_music_renamer_path(info):
    """Authoritative admission for any later integration path-dependent consumer."""
    state = info.get(RESULT_KEY, {})
    value = state.get('verified_final_path')
    if state.get('path_validity') != 'verified' or not isinstance(value, str):
        return None
    path = Path(value)
    return path if path.is_absolute() and path.is_file() else None


def same_path(left, right):
    return isinstance(left, str) and isinstance(right, str) and os.path.normcase(os.path.abspath(left)) == os.path.normcase(os.path.abspath(right))


class MusicRenamerPP(PostProcessor):
    def __init__(self, downloader=None, enabled='true', timeout='30'):
        super().__init__(downloader)
        self._enabled = str(enabled).lower() == 'true'
        self._timeout = int(timeout)
        if not 1 <= self._timeout <= 300:
            raise PostProcessingError('Music Renamer timeout must be between 1 and 300 seconds')
        # Capture bytes once per job. Each item receives a fresh decoded copy.
        self._snapshot = os.environ.get(CONFIG_ENV, '')
        self._job_gate = os.environ.get(JOB_GATE_ENV, '')
        self._job_cancel = os.environ.get(JOB_CANCEL_ENV, '')

    def _emit(self, info, status, *, path=None, recovery='not_reported', issue=None, attention=False, mutation_started=None):
        result = {
            'schema_version': 1, 'id': str(info.get('id') or ''),
            'playlist_index': info.get('playlist_index'), 'rename_status': status,
            'verified_final_path': str(path) if path is not None else None,
            'path_validity': 'verified' if path is not None else 'unverified',
            'recovery_status': recovery, 'issue_code': issue,
            'requires_attention': attention,
            'cancel_requested': _safety.requested(self._job_cancel),
            'mutation_started': mutation_started,
        }
        info[RESULT_KEY] = result
        self._downloader.to_stdout(EVENT_PREFIX + json.dumps(result, ensure_ascii=True, separators=(',', ':')))

    def _admit(self, info):
        if info.get(SOURCE_METADATA_SUCCESS_KEY) is not True:
            raise IntegrationFailure('source_metadata_not_finalized')
        value = info.get('filepath')
        if not isinstance(value, str) or not Path(value).is_absolute() or not Path(value).is_file():
            raise IntegrationFailure('final_file_unavailable')
        path = Path(value)
        if path.suffix.lower() not in ('.opus', '.m4a'):
            return path, False
        if not mutagen:
            raise IntegrationFailure('metadata_reader_unavailable')
        media = mutagen.File(path)
        # Verify only provenance/tag-container admission, never TrackMetadata.
        if media is None or media.tags is None:
            raise IntegrationFailure('final_tags_invalid')
        if path.suffix.lower() == '.opus':
            from mutagen.oggopus import OggOpus
            if not isinstance(media, OggOpus):
                raise IntegrationFailure('final_tags_invalid')
            values = [media.get(key) for key in ('SOURCE_FORMAT_ID', 'SOURCE_CODEC', 'YOUTUBE_ID')]
        else:
            from mutagen.mp4 import MP4
            if not isinstance(media, MP4):
                raise IntegrationFailure('final_tags_invalid')
            values = [media.tags.get('----:com.apple.iTunes:' + key) for key in ('SOURCE_FORMAT_ID', 'SOURCE_CODEC', 'YOUTUBE_ID')]
        if not all(isinstance(v, list) and v and v[0] for v in values):
            raise IntegrationFailure('final_tags_invalid')
        identifier = values[2][0]
        if isinstance(identifier, bytes):
            identifier = identifier.decode('utf-8')
        if identifier != str(info.get('id') or ''):
            raise IntegrationFailure('final_tags_invalid')
        return path, True

    def _invoke_adapter(self, request):
        name = 'Local\\YAD.Rename.' + request['correlation_id']
        # Keep a parent-owned handle open before spawning; both termination
        # layers and adapter share this exact mutex, not a lagging phase log.
        gate = _safety.Gate(name)
        control = ROOT / 'logs' / ('rename-' + request['correlation_id'] + '.tmp')
        control.parent.mkdir(exist_ok=True)
        command = [str(POWERSHELL), '-NoLogo', '-NoProfile', '-NonInteractive',
                   '-ExecutionPolicy', 'Bypass', '-File', str(LAUNCHER),
                   '-TimeoutSeconds', str(self._timeout), '-MutationGate', name,
                   '-CancelFile', str(control)]
        if self._job_cancel:
            command += ['-JobCancelFile', self._job_cancel]
        try:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        except OSError as error:
            gate.__exit__()
            control.unlink(missing_ok=True)
            raise IntegrationFailure('adapter_start_failed') from error
        try:
            payload = json.dumps(request, ensure_ascii=True).encode('utf-8')
            deferred = False
            while True:
                try:
                    stdout, _stderr = process.communicate(payload, timeout=self._timeout + 15 if not deferred else 1)
                    break
                except subprocess.TimeoutExpired:
                    payload = None
                    control.write_text('timeout', encoding='ascii')
                    if gate.acquire():
                        if process.poll() is not None:
                            stdout, _stderr = process.communicate()
                            break
                        subprocess.run([str(TASKKILL), '/PID', str(process.pid), '/T', '/F'],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                        process.communicate(timeout=5)
                        raise IntegrationFailure('adapter_timeout')
                    if not deferred:
                        self._downloader.to_stderr('[MusicRenamer] timeout deferred: waiting for terminal Core result')
                        deferred = True
        finally:
            if process.poll() is None:
                # Unexpected transport/cleanup failures do not authorize
                # killing a possibly executing Core or releasing the job gate.
                process.communicate()
            gate.__exit__()
            control.unlink(missing_ok=True)
        if b'[MusicRenamer] timeout deferred: waiting for terminal Core result' in _stderr:
            self._downloader.to_stderr('[MusicRenamer] timeout deferred: waiting for terminal Core result')
        try:
            lines = [line for line in stdout.decode('utf-8-sig').splitlines() if line.strip()]
        except UnicodeError as error:
            raise IntegrationFailure('malformed_transport') from error
        if len(lines) != 1:
            raise IntegrationFailure('malformed_transport')
        try:
            response = json.loads(lines[0])
        except (ValueError, TypeError):
            raise IntegrationFailure('malformed_transport')
        if isinstance(response, dict) and response.get('adapter_status') == 'error':
            code = response.get('error', {}).get('code', 'adapter_failure')
            raise IntegrationFailure(code if isinstance(code, str) and re.fullmatch(r'[a-z][a-z0-9_]{0,80}', code) else 'invalid_response')
        if process.returncode != 0:
            raise IntegrationFailure('adapter_nonzero_exit')
        return response

    def _project(self, info, original, request, response):
        if not isinstance(response, dict):
            raise IntegrationFailure('malformed_transport')
        if response.get('protocol_version') != 1:
            raise IntegrationFailure('protocol_mismatch')
        if response.get('correlation_id') != request['correlation_id']:
            raise IntegrationFailure('correlation_mismatch')
        if response.get('operation') != 'rename' or response.get('adapter_status') != 'completed' or response.get('error') is not None:
            raise IntegrationFailure('invalid_response')
        classification = response.get('classification')
        status = {'renamed': 'succeeded', 'unchanged': 'unchanged', 'rejected': 'rejected',
                  'failed': 'failed', 'requires_attention': 'requires_attention', 'cancelled': 'cancelled'}.get(classification)
        if status is None:
            raise IntegrationFailure('invalid_response')
        paths, execution = response['path'], response['execution']
        if not same_path(paths['original_path'], str(original)):
            raise IntegrationFailure('source_path_mismatch')
        location, final = paths['final_location'], paths['verified_final_path']
        if location not in (None, 'source', 'destination', 'temporary', 'missing', 'unknown'):
            raise IntegrationFailure('invalid_final_path')
        recovery = execution['outcome'] if execution is not None else 'not_executed'
        expected = {'succeeded': 'renamed', 'no_op': 'unchanged', 'preflight_rejected': 'rejected',
                    'failed_rolled_back': 'failed', 'failed_rollback_incomplete': 'requires_attention'}
        if execution is not None:
            if recovery not in expected or (location not in ('missing', 'unknown') and classification != expected[recovery]):
                raise IntegrationFailure('invalid_response')
            if recovery == 'failed_rollback_incomplete' and classification != 'requires_attention':
                raise IntegrationFailure('invalid_response')
        elif classification not in ('rejected', 'cancelled'):
            raise IntegrationFailure('invalid_response')
        if location in ('missing', 'unknown'):
            if final is not None or classification != 'requires_attention':
                raise IntegrationFailure('invalid_final_path')
        elif final is not None:
            if not isinstance(final, str) or not Path(final).is_absolute() or not Path(final).is_file() or (location != 'temporary' and Path(final).suffix.lower() != original.suffix.lower()):
                raise IntegrationFailure('invalid_final_path')
            operations = execution['operations'] if execution is not None else []
            if len(operations) != 1 or not same_path(operations[0]['final_path'], final) or operations[0]['final_location'] != location:
                raise IntegrationFailure('invalid_final_path')
            if not same_path(operations[0]['source_path'], str(original)):
                raise IntegrationFailure('source_path_mismatch')
            location_field = {'source': 'source_path', 'destination': 'destination_path', 'temporary': 'temporary_path'}.get(location)
            if location_field is None or not same_path(operations[0].get(location_field), final):
                raise IntegrationFailure('invalid_final_path')
            if classification == 'renamed' and location != 'destination':
                raise IntegrationFailure('invalid_final_path')
            if classification == 'unchanged' and (location != 'source' or not same_path(final, str(original))):
                raise IntegrationFailure('invalid_final_path')
            info['filepath'] = final
        elif classification in ('rejected','cancelled') and location is None and original.is_file() and (execution is None or recovery == 'preflight_rejected'):
            # Adapter confirms no execution/mutation; no destination inference.
            final = str(original)
        elif classification != 'requires_attention':
            raise IntegrationFailure('invalid_final_path')
        issue = response.get('rejection_reason')
        if not issue and execution is not None:
            for operation in execution['operations']:
                error = operation.get('rollback_error') or operation.get('forward_error')
                if error is not None:
                    issue = error['code']
                    break
        if not issue:
            codes = response.get('planning', {}).get('issue_codes', [])
            issue = codes[0] if codes else None
        if not issue and status == 'requires_attention':
            issue = 'final_path_unavailable' if final is None else 'recovery_incomplete'
        if not issue and status == 'failed':
            issue = 'execution_failed'
        if issue is not None and (not isinstance(issue, str) or not re.fullmatch(r'[a-z][a-z0-9_]{0,80}', issue)):
            raise IntegrationFailure('invalid_response')
        if classification == 'cancelled' and (execution is not None or response.get('cancellation', {}).get('mutation_started') is not False):
            raise IntegrationFailure('invalid_response')
        self._emit(info, status, path=final, recovery=recovery, issue=issue, attention=status == 'requires_attention',
                   mutation_started=response.get('cancellation', {}).get('mutation_started'))

    def run(self, info):
        if not self._enabled:
            return [], info
        with _safety.Gate(self._job_gate):
            if _safety.requested(self._job_cancel):
                self._emit(info, 'cancelled', issue='operation_cancelled', mutation_started=False)
            else:
                try:
                    result = self._run(info)
                except PostProcessingError as error:
                    if _safety.requested(self._job_cancel):
                        raise DownloadCancelled('Music Renamer job cancelled; infrastructure result unavailable') from error
                    raise
            # Event is emitted/flushed while the job gate remains held. Stop
            # playlist traversal before releasing it, without hiding recovery.
            if _safety.requested(self._job_cancel):
                raise DownloadCancelled('Music Renamer job cancelled after terminal result')
            return result

    def _run(self, info):
        if not self._enabled:
            return [], info
        started = time.monotonic()
        try:
            original, supported = self._admit(info)
            if not supported:
                self._emit(info, 'unsupported', path=original, issue='unsupported_extension')
                return [], info
            config = json.loads(self._snapshot)
            request = {'protocol_version': 1, 'correlation_id': str(uuid4()), 'operation': 'rename',
                       'source_path': str(original), 'config': config}
            response = self._invoke_adapter(request)
            self._project(info, original, request, response)
        except Exception as error:
            code = error.code if isinstance(error, IntegrationFailure) else 'unexpected_bridge_failure'
            self._emit(info, 'infrastructure_failed', issue=code, attention=True)
            self._downloader.to_stderr(f'[MusicRenamer] infrastructure={code}; exception={type(error).__name__}')
            raise PostProcessingError('Music Renamer integration infrastructure failure: ' + code) from error
        finally:
            self._downloader.to_stderr(f'[MusicRenamer] elapsed_ms={int((time.monotonic() - started) * 1000)}')
        return [], info
