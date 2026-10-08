# Music Renamer integration — Phases 1–3

This directory contains the managed runtime/bootstrap, adapter contract harness,
and the invocation used by the opt-in production post-download hook. Naming,
planning, preflight, mutation, and recovery remain owned by Music Renamer Core.

## Bootstrap

The Downloader owns a repository-local Python runtime under
`tools/music-renamer-runtime/`. The bootstrap downloads the pinned official
Windows embeddable package over HTTPS, requires a valid Python Software
Foundation Authenticode signature on its interpreter, enables only its local
`site-packages`, bootstraps local pip, installs the explicitly selected Music
Renamer source as an editable package, and writes a runtime identity manifest.
It does not modify `PATH` or register Python globally.

```powershell
$core = 'D:\path\to\music-renamer'
$commit = git -C $core rev-parse HEAD
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\integrations\music-renamer\Initialize-MusicRenamerRuntime.ps1 `
  -CoreSourcePath $core -ExpectedGitCommit $commit
```

Git is not used by the runtime or adapter. Supplying the expected commit is a
development-time identity assertion recorded in the manifest; package version
and imported source location are independently checked on every health call.

## Health check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\integrations\music-renamer\Invoke-MusicRenamerHealth.ps1
```

The launcher uses the exact managed `python.exe` path. Stdout contains one JSON
result; stderr is reserved for diagnostics. It fails closed on an unavailable
or incompatible runtime, invalid/malformed transport, nonzero exit, correlation
mismatch, Core identity/contract mismatch, GUI dependency leakage, or timeout.

## Single-file rename contract

`Invoke-MusicRenamerAdapterRename` accepts an explicit source path and immutable
configuration snapshot: template, warning acknowledgement, artist aliases,
title cleanup rules, and the two fixed extraction toggles. The adapter wires
these values to public Core types, then runs `RenamePlanner`, `preflight`, and
`RenameExecutor`. It never calculates a destination or mutates a file itself.

Planning errors, preflight rejection, unacknowledged warnings, and execution or
recovery failures are successful transport exchanges with
`adapter_status=completed`. Infrastructure and malformed-transport failures use
`adapter_status=error` or a nonzero process exit. `verified_final_path` is
populated only from the Core execution result.

The result projects Core status, issues, transaction outcome, forward/rollback
state, errors, final location, and verified path. There is no persisted settings
schema, Downloader Undo, or production retry policy.

Do not put credentials or authentication state in the request or result.

## Downloader lifecycle contract tests (Phase 2.5)

The separate [offline lifecycle harness](../../tests/lifecycle/README.md) runs
the bundled yt-dlp executable with generated localhost fixtures and test-only
postprocessors. It verifies SourceMetadata admission, archive timing,
`after_video`, playlist isolation, and the existing PowerShell accounting
behavior. It does not call this adapter or install a production Renamer hook.

## Production hook (Phase 3)

Renaming is disabled by default. Opt in for the Downloader process explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\YoutubeAudioDownloader.ps1 `
  -EnableMusicRenamer
```

For a development/integration configuration, add `-MusicRenamerConfigPath` with
an explicit JSON file. The same switches work alongside `-HeadlessTrackedConfig`.
No Music Renamer GUI settings are read, no tracker schema is changed, and no
settings are persisted. Phase 4 has not supplied a GUI editor.

The conservative default snapshot is:

```json
{"template":"{artist} - {title} [{youtube_id}]","warning_acknowledged":false,"artist_aliases":[],"title_cleanup_rules":[],"extraction":{"artist_quoted_title":false,"title_slash_artist":false}}
```

The source file is read once at job start. The validated snapshot is passed only
to that child process as `YAD_MUSIC_RENAMER_CONFIG`; the PP captures it once and
decodes a fresh item copy. No mid-operation control/settings reads occur. The
disabled child has no Renamer PP registration or inherited config variable.

Registration is `SourceMetadataPrepare` at `video`, `SourceMetadata` at
`after_move`, then `MusicRenamer` at `after_move`. The separate production PP is
in `plugins/music-renamer/yt_dlp_plugins/postprocessor/music_renamer.py`.
It requires the private SourceMetadata success flag, an accessible absolute
final path, a supported Opus/M4A container, and nonempty final SOURCE_FORMAT_ID,
SOURCE_CODEC, and matching YOUTUBE_ID tags. These are admission checks only;
the Core reader still interprets all naming metadata. Unsupported MP3/FLAC/WAV
outputs return `unsupported` without invoking the adapter.

The PP invokes `Invoke-MusicRenamerRename.ps1` using the absolute Windows
PowerShell executable. That launcher accepts the existing adapter JSON request,
reuses `Invoke-MusicRenamerAdapterRename`, and launches only the managed Python.
The frozen yt-dlp process never imports Core or PySide6. No naming grammar or
filesystem rename/move logic exists in the bridge.

Handled outcomes map to `succeeded`, `unchanged`, `rejected`, `failed`, or
`requires_attention`. They return normally and never raise PostProcessingError.
Only admission/infrastructure failures emit `infrastructure_failed` and raise
PostProcessingError. Under the existing ignore-errors policy, later items
continue, child exit becomes nonzero, and archive/after_video follow the reviewed
Phase 2.5 behavior. The outer boundary also classifies unexpected bridge bugs;
it never disguises them as domain rejection.

The compact `__YAD_RENAME_RESULT__` JSON event carries version, video ID,
playlist index, rename status, verified final path, path validity, recovery
status, issue code, and attention flag. Human diagnostics go to stderr and
contain codes/type/elapsed time, not the adapter response or auth material.
The Downloader stores events in a separate RenameResults collection, without
rewriting its existing download Success/Failed sets.

Completion adds rename counts and an explicit job status: `completed`,
`completed_with_rename_errors`, `failed`, or `cancelled`. Requires-attention
results also set the attention flag. For headless callers, the backward-compatible
`success` flag is false for partial completion; additive fields include `status`,
`download_success`, `requires_attention`, `rename_requested`, and `rename_results`. The existing
tracker timestamp API records partial completion as non-success. Rename-aware
callers should inspect the additive status rather than infer download failure
from that boolean. Missing/malformed opt-in events cannot produce full success.

`__yad_music_renamer_result_v1` is the private lifecycle projection. Its path is
authoritative only when `path_validity=verified`; subsequent integration
consumers must call `verified_music_renamer_path(info)` instead of trusting
`info['filepath']`. The bridge updates filepath only from the adapter's verified
operation path, checks its location/source/extension/existence, and never uses
a destination prediction or directory scan. A rejected operation with no Core
execution can retain its existing source. Missing/unknown recovery leaves the
legacy filepath string intact but marks it unverified and exposes no usable
consumer path. A contradictory verified-path claim fails closed.

Private fields are absent from embedded tags and normal clean info JSON. Explicit
raw debug serialization of private info is not a user-facing contract. No bridge
code reads or writes archive files; yt-dlp remains the archive owner. Domain
rejection or handled failure never triggers redownload or automatic rename retry.

Cancellation is transaction-aware. A job-owned named mutex protects the bridge
from invocation through terminal result projection. Stop sets a job-local flag
before acquiring this gate: no subsequent rename may start. If a bridge is
active, Downloader defers Job Object/tree termination and close; its timer
continues draining results. Pause cannot suspend a protected operation, and
window close waits for normal session completion (close again when idle).
Provider/auth stop paths use the same safety boundary without changing their
failure classification. The startup gate prevents mutation before Job Object
assignment completes.

A separate per-invocation named mutex is acquired by the adapter immediately
before `RenameExecutor.execute()`, then retained through final stdout flush and
process exit. Both timeout layers acquire this exact mutex before hard kill.
This is an atomic exclusion boundary, not a racy phase-log observation. Stop
before execution returns `cancelled` with `mutation_started=false` and no
execution. Stop during execution does not interrupt Core; its real terminal
classification, recovery and verified path are preserved, with
`cancel_requested=true`, before job cancellation completes.

Pre-mutation timeout may terminate the adapter/launcher tree. Timeout while the
mutation mutex is held instead signals stop, waits without a hard deadline, and
emits a diagnostic escalation. The eventual Core result, not the elapsed timeout,
determines recovery truth. An indefinitely stuck external operation can therefore
keep cancellation/close pending; normal UI shutdown cannot bypass this policy.
External process kill, runtime crash, OS crash, power loss, or forced application
termination remain outside this guarantee. Missing terminal results are
infrastructure failures requiring attention, never inferred recovery paths.
Core transactions remain best-effort, not atomic, ACID or crash-safe. There is
no Downloader Undo/recovery UI or automatic retry.

Focused verification:

```powershell
$env:PYTHONDONTWRITEBYTECODE = '1'
& .\tools\music-renamer-runtime\python.exe -B -m unittest discover `
  -s tests/production-hook -p 'test_*.py' -v
pwsh -NoLogo -NoProfile -File .\tests\production-hook\Phase3.Tests.ps1 `
  -ManagedRuntimeRoot (Resolve-Path .\tools\music-renamer-runtime).Path
```

Tests use localhost/generated fixtures, fake domain/transport responses, and
real Core rename/rejection on Opus/M4A copies. Whole-file SHA256 before/after the
bridge checks audio, embedded metadata, and cover integrity. Cancellation tests
load the real Downloader process controller, exercise safe startup cleanup, and
run real Core staging/rollback barriers under the bundled yt-dlp process. Tests
cover pre-mutation cancellation, planning/preflight, success after stop, restored
failure, incomplete recovery, mutation timeout and an actual adapter crash.
