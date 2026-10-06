# Music Renamer integration — Phases 1–2

This directory is a development-only runtime/bootstrap and adapter contract
harness. It does not register a yt-dlp postprocessor or participate in the
Downloader lifecycle. Phase 2 can rename one explicitly supplied `.opus` or
`.m4a` fixture through Music Renamer Core for contract verification.

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
schema, automatic download integration, Undo, or production retry policy.

Do not put credentials or authentication state in the request or result.
