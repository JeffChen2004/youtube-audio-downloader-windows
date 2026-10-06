# Phase 2.5: offline yt-dlp lifecycle contracts

This harness runs the **bundled `tools/yt-dlp.exe`**, not a separately installed
Python yt-dlp package. The reviewed executable baseline is **2026.08.19**.
Both the runner and test plugin report version drift explicitly. Updating the
pin requires rerunning and reviewing the matrix; this is a test baseline, not a
production restriction on future yt-dlp versions.

## Running

```powershell
$env:PYTHONDONTWRITEBYTECODE = '1'
& .\tools\music-renamer-runtime\python.exe -B -m unittest discover `
  -s tests/lifecycle -p 'test_*.py' -v
pwsh -NoLogo -NoProfile -File .\tests\lifecycle\Accounting.Tests.ps1
```

The runner uses the managed Python's standard-library unittest/HTTP server plus
its existing mutagen dependency. FFmpeg creates tiny Opus, M4A, WebM, and cover
fixtures in a unique directory below `tests/lifecycle`. A custom test extractor
constructs a two-item playlist using only `127.0.0.1` URLs. No YouTube, cookies,
PO Token, external service, installed global Python, or real music sample is
needed. A sandbox blocking loopback sockets needs permission for local HTTP.
Temporary fixtures are removed by their owner; no existing external pytest
temporary directories are inspected or cleaned.

`--no-plugin-dirs` disables ambient/default plugins; only repository plugins and
the test collection are loaded. Test PPs are exported only from the test plugin.
Production startup never points at this collection. The SourceMetadata subclass
calls the real implementation, injects failures only in fixtures, and restores
test-only invalid path/ext changes before the next stage.

## SourceMetadata admission

`SOURCE_METADATA_SUCCESS_KEY = '__yad_source_metadata_finalized_v1'` is a private
process-local info flag. `SourceMetadataPP.run()` removes any stale flag before
doing work and sets it to `True` only after the selected writer returns from
`save()` and finalization completes. Writer errors, missing/invalid media, and
unsupported formats leave it absent. Existing writer exception semantics are
unchanged: raw mutagen/OSError failures are not automatically PP errors.

This is not a success guarantee for every upstream PP, nor a read-back guarantee
for every tag or cover. A downstream consumer must first require the flag and
then validate its own required final tags. The fake consumer reads SOURCE_CLIENT
and title from the completed file. A separate assertion verifies embedded cover.
Reversed registration order and deliberately invalid tag validation must deny
admission without entering domain logic.

The flag is not passed to embedded-tag writers. Default clean `.info.json` output
and `YoutubeDL.sanitize_info(..., remove_private_keys=True)` exclude it, including
nested requested-download copies. Explicit raw/debug serialization of private
info is not a supported user-facing transport; future result writers must use
an explicit projection or clean serialization. The flag remains internal and
does not extend the public Downloader metadata schema.

## Verified executable findings

Each matrix run replays the merged child output through the actual PowerShell
accounting functions and `Complete-DownloadSession`. AST extraction loads only
the functions, with UI, output draining, and persistence stubbed out. No GUI or
tracker schema is loaded or written.

| First item | Child exit | yt-dlp archive | after_video | Second item | Current item sets | Current tracker/job |
| --- | --- | --- | --- | --- | --- | --- |
| renamed / unchanged / not requested | 0 | both items | both | continues | Success=2, Failed=0 | success |
| rejected / failed, restored | 0 | both items | both | continues | Success=2, Failed=0 | success; rename concern is invisible |
| requires_attention, unknown or missing | 0 | both items | both | continues | Success=2, Failed=0 | success; attention is invisible |
| SourceMetadata PP error or denied admission, ignore-errors | 1 | both items | both | continues | Success=2, Failed=0 | failure due to child exit |
| downstream infrastructure PP error, ignore-errors | 1 | both items | both | continues | Success=2, Failed=0 | failure due to child exit |
| infrastructure PP error, abort-on-error | 1 | none | none | not processed | Success=0, Failed=1 | failure |
| raw RuntimeError / writer OSError, ignore-errors | 1 | second only | second only | continues | Success=1, Failed=1 | failure |

Under `--ignore-errors`, yt-dlp catches **PostProcessingError**, reports ERROR,
sets a failure exit code, and continues same-stage PPs. The test observes that
the current item's archive entry is absent at downstream admission and present
by the `after_video` observer. Handled domain results return normally and do not
emit ERROR. Archive membership and writes belong entirely to yt-dlp: all probes
only read it. A raw exception aborts the current item before archive/after_video,
but the outer error handler still processes the next item under ignore-errors.

`after_video` does **not** prove every PP succeeded. The real Downloader parser
currently performs `Failed.Add` on ERROR, then `Success.Add` and `Failed.Remove`
on `__YAD_ITEM_SUCCESS__`. The standalone accounting test asserts this known
behavior rather than fixing or hiding it. Child nonzero still makes the current
tracker/headless job fail through `Complete-DownloadSession`.

The fixture status transport carries `not_requested`, `succeeded`, `unchanged`,
`rejected`, `failed`, and `requires_attention` separately. The proposed test-only
job projection maps handled rejection/failure to `completed_with_rename_errors`,
unknown/missing recovery to `requires_attention`, and child failure to `failed`.
It does not replace or extend production persistence.

## Future filepath contract and Phase 3 admission

The fake result projects a copy of a path field, never runtime `info['filepath']`:

- renamed: use the supplied verified destination;
- unchanged: retain the verified original;
- rejected / restored: use the supplied verified Core/adapter location;
- missing / unknown: keep the existing info value, expose no verified final
  path, and demand attention; never invent a usable path.

The tests assert that the fake renamed destination is never created, while the
runtime media path remains unchanged. This defines an update rule without
performing a rename or calling the real adapter.

Phase 3 needs a thin hook that verifies upstream admission, validates final tags,
and projects the adapter's outcome. It also needs a separate rename result
transport/job policy: the existing Success/Failed sets cannot represent domain
errors or incomplete recovery. Decide how a possibly stale runtime filepath is
protected after missing/unknown results, and how raw exceptions are converted to
an intentional failure policy. Archive membership is download completion and
must never be rewritten to implement rename retries. No production hook exists
in this phase.
