# Observation, actions, console and recordings

The connector now provides a shared observation session. Reload the connector in a fresh Roblox session after updating the host; older connectors will report unsupported commands. Existing connectors are not forcibly unloaded.

## Workflow

1. `list-clients`, then `set-active-client` (or supply `clientId`).
2. `observe` with `ui-debug`, `gameplay-debug`, or `performance`.
3. `gui-query` / `gui-inspect` to identify a target. Reuse its handle, not its display path.
4. For background GUI work, use `gui-activate` / `gui-set-text` with the observation ID and target. Use `cursor-click` / `cursor-drag` for physical-input semantics; alternatively use Roblox screen coordinates.
5. Poll `action-status`; inspect the before/after observations and postcondition. Dispatch accepted, input observed, and expected effect observed are separate evidence.
6. Use `console-read` with the returned `nextCursor` for incremental logs. Its cursor belongs to one connector session; retain `sessionId` with it.

`input-sequence` and `scenario-run` accept up to 32 key, text, mouse, scroll, or wait steps. They return handles immediately. Use `action-cancel` / `scenario-cancel` to cancel. Observation, actions and wait-only sequences do not require foreground focus. Client-local held inputs survive focus changes; desktop-held input is released on focus loss. Failure, cancellation and connector disconnect release all held input. Executor OS-input fallback is disabled unless Roblox focus is verified; it must never type/click into another application. Successful function calls alone do not prove behavior.

### Background GUI operations

- `gui-activate` dispatches exactly one selected `Activated`, `MouseButton1Click`, or `MouseButton2Click` signal through the executor's `firesignal`. It requires a visible, unobstructed, interactable target and a fresh observation. It does not move the desktop cursor or synthesize a physical click. `Activated` receives `nil` as its InputObject and a click count of 1; callbacks that require a real InputObject may not work. Supply a property postcondition to verify the game effect. Signal delivery alone returns `unverified`; do not blindly retry after an earlier unverified pointer click.
- `gui-set-text` directly replaces a visible editable TextBox's `Text` without focusing the window or TextBox. It verifies readback. It does not simulate typing, Enter, or submission; use the relevant button separately if appropriate.
- `cursor-state` reports `backgroundPolicy: "client-local-only"` inside cursor metadata. The connector probes `CreateVirtualInput` wherever available, then VirtualInputManager. Neither availability nor a non-throwing call guarantees background input processing. Potassium live tests accepted both virtual mouse routes without activating the fixture button; direct activation and Unicode text replacement passed with `focused=false`.
- Background is not the same as minimized/suspended. Runtime observation needs a connected, executing Roblox process; pixel capture needs the app to keep producing frames. No focus spoofing, window activation or input to other applications is used.

Pointer targets reject stale observations, changed viewport/inset geometry, fully clipped targets, and intercepted hit-test points. Inactive transparent CoreGui containers remain in hit-test evidence but do not intercept input. GUI metadata is not a pixel-accurate visibility oracle; postconditions remain important. The optional overlay shows requested and observed positions separately.

## Console coverage

`console-read` returns structured entries with sequence, time, level, source, session/client identity, cursor, and drop/gap counters. It seeds up to 200 available `LogService:GetLogHistory()` entries, then collects `MessageOut`. `contains` is case-insensitive literal text; `level` accepts Roblox MessageOutput/Warning/Error/Info values. A filtered read advances over inspected nonmatching events.

`get-console-output` remains available for the existing text-oriented history workflow. Neither tool claims access to executor-private console entries that Roblox LogService does not receive. A broken Potassium console endpoint does not imply Roblox LogService is empty.

## Recordings and evidence

`recording-start` collects a baseline followed by sampled observations and journal events autonomously for up to 120 seconds. Default interval is one second; minimum is 500 ms. This is **sampled evidence, not continuous encoded video**. A reconnect ends the recording instead of silently mixing sessions. `unreadEventCount`, journal gaps and dropped retention counts disclose incomplete history.

Tools: `recording-start`, `recording-stop`, `recording-status`, `recording-list`, `recording-release`, `recording-import`, `recording-read`, `recording-timeline`, `recording-search`, `recording-state-at`, `recording-frame`, `recording-analyze`, `recording-compare`.

State-at returns an actual retained sample at/before the requested time, never invented interpolation. Search operates on captured structured text/events. Analyze counts evidence and reports errors/gaps; it is not a vision-model claim. Compare labels cross-session evidence and does not infer causes.

Observations and frames expose `roblox://evidence/{id}` resources scoped to the MCP connection. Each connection retains at most 256 evidence items / 16 MiB, and four recordings of at most 1,000 events / 4 MiB each. Server-wide evidence and recording pools each cap at 64 MiB. Old evidence can expire; recordings report dropped entries. Release recordings when finished. Session closure cancels collection and releases history. No executor filesystem persistence is used.

### Imported video

FFmpeg/ffprobe are installed as dependencies. Configure the explicitly allowed import directory:

```powershell
$env:ROBLOX_MCP_RECORDING_ROOT = 'C:\MCP-recordings'
# Optional absolute binary paths if they are not on PATH:
$env:ROBLOX_MCP_FFPROBE = 'C:\ffmpeg\bin\ffprobe.exe'
$env:ROBLOX_MCP_FFMPEG = 'C:\ffmpeg\bin\ffmpeg.exe'
```

`recording-import` accepts an existing local MP4/MOV/MKV/WebM/AVI of at most 512 MiB under that directory. Symlinks are resolved before checking scope. No remote URL downloads. The asynchronous worker indexes real presentation timestamps from at most the first 120 seconds, retaining up to roughly 900 indexed frame choices. Frame extraction selects the corresponding decoded frame index and reports its PTS. Processing has output and 30-second wall-time limits. Missing binaries or unsupported media produce explicit failures. Imported video has no synchronized game-state evidence.

### Capture location and limitations

The Windows host uses a persistent asynchronous PowerShell/PrintWindow worker with bounded queue, timeout, explicit native return checks, in-memory JPEG encoding and process/window identity checks. Frames include source/returned dimensions, crop, DPI, origin, time bounds, capture source and geometry revision. Minimized/changed windows are rejected; no window is restored or focused automatically. Cursor pixels are not included.

`capture-bind` associates an explicitly selected Roblox client with PID/HWND. This association is operator-provided, not cryptographic proof that the window belongs to the client. `observe(capture=true)` and instrumented frame capture require this binding. `cursor-click-frame` rechecks the process, geometry, frame age and matching viewport dimensions; uncertain mappings fail instead of guessing.

Continuous recording uses the new Windows Graphics Capture worker, or frames uploaded by a paired Windows/Android companion. Railway receives device frames; it does not capture a remote device by itself. The existing screenshot tool remains a diagnostic PrintWindow backend. PrintWindow success does not guarantee that a renderer supplied new pixels. WGC supplies actual frame presentation timestamps and includes cursor pixels, but its window coordinate space is not automatically a Roblox viewport mapping.

## Device capture and video

Thirteen media/companion tools extend the observation surface: `companion-pair`, `companion-list`, `companion-revoke`, `companion-frame`, `server-telemetry-read`, `server-source-resolve`, `video-start`, `video-export`, `vision-status`, `frame-ocr`, `frame-compare`, `frame-describe`, and `recording-visual-analyze`. With the two background GUI tools, the complete server now registers 103 tools.

### Windows

Run `npm run build:capture` once on the capture PC (requires Rust/Cargo and Windows C++ build tools). This compiles the pinned `windows-capture` Rust helper and copies its executable into the server build. `ROBLOX_MCP_WGC_BINARY` can select an explicitly installed helper instead.

For a local MCP host: select a client, `capture-bind` its exact PID/HWND, then `video-start` with `source="window"`. For Railway: create `companion-pair` with `kind="capture"`, then run `companions/windows/capture.cmd` on the Roblox PC. Enter the host URL, choose the exact Roblox window, and enter the one-use code. The Windows companion captures for up to 120 seconds; Ctrl+C stops. If WGC fails, it offers an explicitly labeled 1 fps PrintWindow diagnostic fallback.

### Android / BlueStacks

Build with `npm run build:android` on Windows with JDK 17+ on PATH. The script downloads checksum-verified, pinned Android platform/build-tools archives into `.build-tools`, compiles the Java sources, and verifies the resulting development APK signature. Output: `companions/android/app/build/ai-mcp-capture.apk`. It does not install or launch the app automatically.

Install that APK on the device/emulator. Open **AI-MCP Capture**, enter the HTTPS server URL and code from `companion-pair(kind="capture")`, then press **Pair and share Roblox**. Android presents its screen-sharing consent dialog. Select Roblox where app sharing is available; older Android versions share the whole display. A persistent notification shows capture status and **Stop capture**. No microphone/audio capture, input injection or saved credentials. Uploads run at up to 5 fps for at most 10 minutes. Rotation/resize replaces the image surface without reusing a MediaProjection consent token.

The app targets Android 15 and requires Android 8+. No Android device was connected during initial implementation: APK compilation/signing and host-side protocol tests are verified; actual device projection/rotation/upload behavior still needs device testing. iOS is not included.

### Recording workflow and limits

1. Keep the owning MCP session connected. Pairings are one-use (10-minute claim window); the scoped upload credential lasts at most 24 hours and is revoked on session close or `companion-revoke`. These credentials do not replace or rotate the existing loader credential.
2. Start the capture companion; `companion-list` reports liveness, sequence and dropped frames. `companion-frame` retains its latest image as an evidence resource.
3. Call `video-start` with the same `clientId`, `source="companion"`, and `companionId`. Optional runtime observations are collected separately. If the connector cannot supply observations, explicitly set `sampleRuntime=false` for video-only recording.
4. Stop with `recording-stop`; poll `recording-status` through `processing` to `stopped` or `failed`. Use `recording-frame` and `recording-visual-analyze` while frames remain retained.
5. `video-export` returns a relative `/api/recording-video?id=...` download URL requiring the **agent** bearer token, plus a resource containing capture timestamps. The endpoint supports HTTP byte ranges. `recording-release` or session closure removes owned video files.

Silent H.264 MP4 encoding preserves irregular capture PTS using a VFR timeline. A documented terminal duplicate holds the final frame for 100 ms. Resizes are letterboxed into the first frame's output size; original per-frame dimensions remain in the manifest. Capture/host alignment uses first receipt and explicitly reports unknown network delay—not fictitious exact synchronization. Limits: 120 seconds, 15 fps maximum (Android 5), 1,800 frames, 128 MiB frame files per recording / 384 MiB globally, and 32 MiB encoded video. Overruns fail explicitly. Frames are processed serially with backpressure instead of unbounded queues.

## OCR and vision

`frame-ocr` uses bundled English Tesseract data locally, returning text, confidence, word boxes and the normalized image dimensions. It does not download language data at runtime. Long results are paged through evidence resources. `frame-compare` computes normalized pixel differences and geometry changes; this identifies change candidates, not semantic game events.

`recording-visual-analyze` accepts up to six explicit timestamps and `mode="ocr"`, `"scenes"`, or `"vision"`. It returns the actual selected frame times. Configure an existing Ollama-compatible vision service with `ROBLOX_MCP_VISION_URL`, `ROBLOX_MCP_VISION_MODEL`, and optional `ROBLOX_MCP_VISION_TOKEN`. HTTPS is required except for loopback HTTP. `frame-describe` and vision-mode analysis require `confirmUpload=true` before sending the selected images. No model download, paid account or remote provider is selected automatically. Provider responses are labeled inference, bounded, and cannot redirect requests. A mock provider verifies the protocol; model answer quality requires a configured model.

The npm dependency audit is separate from native binary security; administrators can override the FFmpeg/ffprobe paths with maintained local builds. FFmpeg, Tesseract, Sharp, Windows Capture and Android SDK components retain their respective upstream licenses.

## Project diagnostics

Opt-in project instrumentation may use the connector's session-local API:

```lua
local diagnostics = getgenv().MCPDiagnostics
diagnostics:SetBuild({ commit = "your-project-commit", placeVersion = game.PlaceVersion })
diagnostics:Emit("round-start", { round = 4 })
local unregister = diagnostics:RegisterState("round", function()
    return { round = 4, phase = "active" }
end)
-- unregister() when this export is no longer relevant.
```

`diagnostic-state`, `collector-status`, and `observation-coverage` expose these named exports, build identity, and coverage. Up to 16 exports are allowed; reads time out after two seconds. Avoid side effects or non-yielding loops in export callbacks. Events must be bounded JSON-compatible values. History stores copied metadata and weak instance handles, not strong references keeping historical objects alive.

For server evidence, install `companions/studio/ServerCompanion.luau` as a ModuleScript in **ServerScriptService** in your own project, and adapt `example.server.luau`. Enable **HTTP Requests** in Game Settings > Security. Create `companion-pair(kind="server", placeId="...")`, optionally restricted to a job ID, and pass its one-use code into the server-only setup. No credential is placed in replicated storage.

The module batches opt-in console entries, `State(name, value)`, `Emit(kind, name, data)`, timed `Span` results, build identity and explicit source-map metadata. `server-telemetry-read` pages these events; `server-source-resolve` connects a logical script path to the supplied revision/path. Buffers are bounded and copied, network failures back off and report uncertain-delivery gaps, and `Stop()` disconnects collectors and clears the credential. It does not execute remote commands, read arbitrary source or instrument a server you do not control. The module passes injected-service Luau tests; no Studio instance was connected for live server testing.

Uninstrumented server-only/streamed-out state, exact source archives, physics ownership and full animation/audio/network domains are not inferred. The standard MCP resources and handle/polling workflow are implemented; experimental MCP Tasks and protocol extensions are not advertised.
