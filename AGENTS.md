# Downloader Repository Guidance

## Architecture boundaries

- Keep authentication, provider lifecycle, yt-dlp argument construction, download-session control, and per-item accounting in the Downloader pipeline.
- Keep tracker persistence separate from downloading. The Monitor may orchestrate tracker workers, and the Task Scheduler manager may launch the Monitor, but neither should reimplement authentication, format selection, metadata, or download logic.
- GUI and headless tracker execution must use the same Downloader pipeline. Headless execution must not load or create WinForms UI, message boxes, or interactive pickers.

## Authentication and download contract

- Authentication is fail-closed. When the selected Cookie file, browser authentication, or Cookie Bridge export or validation fails, stop the affected job; do not retry anonymously, reuse stale credentials, or silently switch authentication modes.
- Preserve-source mode selects formats independently for every item using `774 > 141 > 251 > original-audio fallback`.
- In preserve-source mode, keep original audio: formats 774 and 251 may be remuxed from WebM to Opus, while format 141 remains AAC/M4A. Audio encoding is allowed only in the explicit re-encode mode.
- Preserve-source downloads use the authenticated `web_music` path and managed PO Token provider. Provider failure must not silently downgrade the client or source quality.
- Format provenance must come from the audio format actually selected for that item, not from a probe prediction, the first playlist item, or the first selector alternative.

## Output lifecycle and naming safety

- Download-stage naming must retain a stable source identity sufficient to avoid collisions between same-title videos and to trace an output back to its source. The current implementation uses the YouTube video ID.
- Post-download consumers that require the final path, final extension, or embedded tags must run only after the output has reached the stable post-move stage. Consumers of Downloader final metadata must run after source metadata finalization and validate the fields they require.
- Keep per-item success accounting at the final per-video stage rather than download start or format selection. While `--ignore-errors` is enabled, an `after_video` marker alone is not proof that every postprocessor succeeded; changes to this error policy must verify statistics and archive behavior.
- Filename-only or path-only operations must not rewrite the audio stream or discard embedded metadata or cover art unless the task explicitly targets media mutation.

## Metadata contract

- Preserve the embedded standard metadata semantics for title, artist, album, track number, and date when reliable source values exist.
- Preserve these custom metadata keys and their meanings:
  - `SOURCE_FORMAT_ID`
  - `SOURCE_CODEC`
  - `SOURCE_ABR`
  - `SOURCE_CLIENT`
  - `SOURCE_QUALITY`
  - `YOUTUBE_ID`
  - `SOURCE_URL`
  - `DOWNLOAD_DATE`
  - conditional `PLAYLIST_TITLE`, `PLAYLIST_INDEX`, and `PLAYLIST_ID`
- Keep provenance truthful. Do not synthesize artist, album, bitrate, format ID, client, playlist position, or source quality when yt-dlp did not provide reliable data.
- Container-specific tag encoding belongs in the metadata postprocessor. Other Downloader components and integrations should consume the semantic fields rather than duplicate container-specific mapping logic.
- Preserve embedded cover art on supported outputs without re-encoding the audio stream.

## Playlist and headless semantics

- Treat tracker persistence, yt-dlp download archives, authentication modes, and headless result and exit behavior as compatibility boundaries. Changes require an explicit compatibility or migration decision.
- Tracker configuration writes must remain atomic. Temporary, backup, hidden, or invalid support files must not prevent valid trackers from running.
- Isolate ordinary item and tracker failures so unrelated later items or trackers can continue. Fatal authentication, configuration, provider, or user-stop conditions may terminate the affected job and must not fall back to a weaker mode.
- Let yt-dlp own archive membership and duplicate protection; do not infer or rewrite archive success from filenames or output-folder contents.
- Preserve noninteractive scheduled execution and single-instance Monitor behavior.

## External integration boundaries

- If Music Renamer Core is integrated, consume its public Core contracts rather than reimplementing metadata interpretation, template parsing, sanitization, collision analysis, identity validation, planning, or no-overwrite filesystem mutation in Downloader.
- Keep optional integrations isolated from unrelated GUI and test dependencies. Integrating a Core library must not pull another application's GUI runtime into normal Downloader startup.
- Music Renamer is explicit opt-in. Keep rename outcomes separate from download accounting and preserve yt-dlp archive ownership. A downstream path consumer must use the integration's verified-path validity, never assume a nonempty `filepath` remains usable after recovery failure.
- Active jobs and queued batches must use a validated immutable integration configuration snapshot; later settings edits must not change in-flight operations.
- The Music Renamer post-download bridge requires SourceMetadata finalization and final-tag admission, invokes the managed adapter, and leaves naming and mutation to Core. Handled domain outcomes must not become postprocessing infrastructure errors.
- Do not forcibly terminate an external filesystem mutation integration inside its mutation critical section. Normal cancellation and timeouts must allow a truthful terminal/recovery result before cleanup, without starting new operations after a stop request.
- Do not treat an integration design, adapter class, settings schema, transport protocol, or failure-statistics model as existing behavior until it has been implemented and verified in this repository.

## Runtime and sensitive data

- Do not silently introduce a dependency on ambient system Python or another undeclared global runtime. New runtime requirements need an explicit bootstrap, packaging, or deployment contract.
- Do not treat the runtime availability of a particular development machine as a repository invariant.
- Never log or commit Cookie values, PO Token values, browser session material, or authentication state.
- Downloaded media, runtime binaries, tracker runtime state, archives, and other generated runtime artifacts must not be accidentally committed.
