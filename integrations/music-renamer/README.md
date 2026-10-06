# Music Renamer integration — Phase 1

This directory is a development-only runtime/bootstrap and contract harness.
It does not register a yt-dlp postprocessor and cannot rename files.

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

The request contains only operation, correlation ID, and an immutable fixture
configuration snapshot (`template`, warning acknowledgement, and optional
fixture path). Do not put credentials or authentication state in this channel.
