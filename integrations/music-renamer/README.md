# Music Renamer integration — Phases 1–4

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

Phase 4 adds a visible GUI entry point and Downloader-owned persisted settings;
the explicit CLI opt-in below remains compatible. Without a CLI override,
headless/scheduled jobs consume the persisted settings described below.

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

## GUI, settings and result presentation (Phase 4)

The Music Renamer tab provides opt-in, template input, Core validation feedback,
the two existing extraction toggles, and a global explicit warning acknowledgement
(false by default). Validation is also enforced at job start, not only by UI.
No local template parser, alias grammar, extraction pattern, planner or executor
is introduced. `validate_config` is a non-mutating adapter operation using the
same `_translate_config` and public Core validators as `rename`. Invalid domain
configuration returns a normal single JSON response with issue codes; transport
and infrastructure errors retain failure exit semantics. Health/rename contracts
remain compatible.

Settings belong to Downloader, at ignored `data/music-renamer.json`, not
`%APPDATA%\Music Renamer` or tracker JSON. Tracker schema v1 is unchanged. Missing
settings mean deterministic disabled defaults and do not create a file:

```json
{
  "schema_version": 1,
  "enabled": false,
  "template": "{artist} - {title} [{youtube_id}]",
  "warning_acknowledged": false,
  "artist_aliases": [],
  "title_cleanup_rules": [],
  "extraction": {
    "artist_quoted_title": false,
    "title_slash_artist": false
  }
}
```

All fields are required; unknown fields/versions and malformed/type-invalid JSON
fail closed with no partial application, migration, rewrite or template fallback.
There is no older versioned settings schema to migrate. Future migration requires
an explicit separate implementation. Legacy `-EnableMusicRenamer
-MusicRenamerConfigPath <path>` still accepts the Phase 3 unversioned adapter
config (without schema_version/enabled), by explicit request only; it does not
silently import or overwrite persisted settings. In GUI mode that opt-in is
reflected in the visible controls. In headless it overrides persisted settings.

Saving uses a same-directory unique UTF-8 temp and atomic File.Replace/File.Move,
with temp cleanup and preservation of old bytes on failure. Saving enabled
settings requires runtime health and full semantic validation. Disabled settings
can be saved without the optional runtime; their semantics must still pass Core
before enabling or starting any rename. GUI load errors block use/save until the
file is repaired externally and the app restarted; displayed disabled defaults
are not applied as a fallback for a corrupt file.

Aliases/cleanup are config-only in this first UI. Save once to obtain the complete
schema, close Downloader, edit JSON, then reopen and validate. The GUI preserves
these arrays when saving basic controls. Examples of array entries:
`{"source":"旧名","target":"正式名"}` and
`{"kind":"remove_suffix","text":" (official)"}`. Cleanup kinds are the existing
Core `remove_prefix`/`remove_suffix`; duplicate/conflicting rules are validated by
Core. Extraction stays explicitly `Artist「Title」` then `Title ⧸ Artist`;
normalization stays aliases then cleanup. This is not a clone of Music Renamer GUI.

Job startup captures GUI state (or persisted config for headless), validates
shape, managed runtime health, manifest-bound Core identity, PySide6 isolation,
and Core semantics, then passes immutable adapter-config JSON into the existing
bridge. An entire queued GUI tracker batch captures one snapshot before queueing.
No item rereads settings or controls; edits during a job/batch affect only the next
one. GUI drafts do not automatically affect scheduled jobs: press Save. Health
failure is actionable before tool setup/child launch, never auto-disable-and-run.
Headless imports only nonvisual modules and shares the same validation/pipeline.

Per-item human logs include machine status, short issue code and only verified
paths, independent of the compact machine events. `not_requested` is a display
state for disabled integration; `unsupported` is a safe skip for non-Opus/M4A;
`succeeded`/`unchanged` are normal; `rejected` reports issue and verified original
path; `failed` reports whether Core restored the source; `requires_attention`
is prominently marked for manual inspection. Unverified/missing/unknown locations
display `最終檔案位置無法確認` without stale filepath. No guessed destination is shown.
Independent Music Renamer counters include cancellation and infrastructure
failure; the download success/failure/skipped sets and yt-dlp archive are untouched.
`completed_with_rename_errors` is labelled partial rename completion, not download
failure. `cancelled` retains the separate attention flag and actual Core result.

Stop during a protected operation shows `正在完成安全檔案操作`; the stop control can
request safe cancellation without pausing Core. It offers no hard-kill route.
Terminal recovery truth is retained. A hung Core may delay cancellation indefinitely;
external kill/crash/OS failure remain fail-closed, not crash-safe. No Undo, retries,
new patterns, shared GUI settings, telemetry or observation dataset are added.

Phase 4 focused tests (generated copies only):

```powershell
$env:PYTHONDONTWRITEBYTECODE = '1'
pwsh -NoProfile -File tests/music-renamer/Phase4.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File tests/music-renamer/Phase4.Tests.ps1 -Gui
& tools/music-renamer-runtime/python.exe -B -m unittest discover -s tests/music-renamer -p test_adapter_config.py -v
```
