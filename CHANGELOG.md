# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

### Added

- **Transcript Cleanup feature** — new "Cleanup" Settings tab with three
  modes:
  - **Off**: raw Whisper output (default for new users)
  - **Local**: on-device cleanup via Apple Intelligence
    `FoundationModels` framework (macOS 26+). Removes filler words,
    fixes punctuation, preserves meaning. ~200–500 ms latency, free,
    fully private.
  - **Cloud**: Anthropic Claude API (BYOK) with API-key entry stored
    in macOS Keychain (`ClaudeAPIKeyStore`). One-retry on 429/529 with
    backoff; falls back to raw on any error so cleanup never blocks
    paste.
  Routing lives in `PolisherFactory`; `MiniRecorderView.processRecording`
  applies cleanup with `try?` fallback. Both providers share the same
  cleanup prompt for consistent behavior across modes.
- **System Default microphone option** — pinned to top of the input-
  device picker, with subtitle showing the resolved underlying device
  ("Currently: MacBook Pro Microphone"). New `SystemDefaultInputWatcher`
  uses Core Audio property listener on
  `kAudioHardwarePropertyDefaultInputDevice` to track changes (the only
  reliable signal — AVFoundation has no equivalent on macOS).
  Aggregate devices (including macOS 26's auto-generated "CA default
  device aggregate") are transparently unwrapped to their first active
  subdevice.
- **Synthesized start/stop feedback chimes** on recording. 528 Hz "Love"
  → 396 Hz "Liberation" sine pair with exponential-decay envelope.
  Generated at runtime via AVAudioEngine — no bundled audio assets.
  Opt-out via `defaults write com.2048labs.speaktype feedbackSoundsEnabled -bool false`.
- **Compact recorder panel** — 260×50 → 140×30 (68% area reduction).
  Waveform: 15 bars → 11 bars stretched corner-to-corner. Inline chip
  shows the active model (gearshape icon); language and recording-mode
  toggle moved to right-click context menu.
- **File-backed transcription history** — moved from a UserDefaults
  blob (which buffered writes and lost data on SIGKILL during
  `make build`) to NDJSON at
  `~/Library/Application Support/SpeakType/history.ndjson`. Append-only
  via `FileHandle.seekToEnd` (O(1)), atomic rewrite on edit/delete,
  malformed-line recovery on load. Existing UserDefaults data migrates
  on first launch.
- **`AppDelegate.syntheticEventSentinel`** — 64-bit sentinel
  (`'SPEK'`) stamped via `CGEvent.eventSourceUserData` on every event
  the app posts itself, so handlers can identify and skip them.

### Fixed

- **Whisper end-of-audio hallucinations** ("Thank you", "Thanks for
  watching" on silent recordings). Three-layer defense:
  1. VAD chunking (`DecodingOptions.chunkingStrategy = .vad`) —
     trims silence before the model sees it
  2. Tightened decoder thresholds (noSpeech 0.55, logProb -0.8)
  3. Output-side phrase filter in `normalizedTranscription`:
     standalone hallucinations → empty; trailing hallucinations
     with ≥5 prefix words → strip just the trailing
  Phrase list sourced from openai/whisper #928 / #1783 and
  transformers PR #27658.
- **Auto-paste NSBeep when target had no editable focus.** Posting
  Cmd+V to a frontmost app whose focused element is non-editable
  walks the responder chain to `noResponderFor:`, which beeps by
  design. New `PasteEligibility` AX preflight checks the focused
  element's role / insertion-point / value-settable status before
  posting. Bundle-ID allowlist seeded with Warp for apps whose AX
  reporting false-negatives but whose paste reliably works.
- **NSBeep on rapid Fn presses** — synthetic F19 from
  `suppressEmojiPicker` reached `KeyCaptureView.keyDown` and fell
  through `super.keyDown`, triggering NSBeep. Filter sentinel-tagged
  events at the CGEventTap level (returns `nil` to drop them from the
  event stream entirely) — avoids any responder-chain interaction.
- **Auto-paste race when target app activates asynchronously.**
  `app.activate()` returns immediately but focus transfer is multi-
  stage — fixed 500ms sleep was unreliable. Replaced with
  `NSWorkspace.didActivateApplicationNotification` observer with 800ms
  timeout fallback.
- **Mini recorder waveform meter stuck at zero on external mics.**
  Many USB mics deliver Int24 samples; the level-meter code only
  handled Float32 / Int16 / Int32. Forced canonical Float32 output via
  `AVCaptureAudioDataOutput.audioSettings` so all devices route
  through the same handler.
- **Auto-paste failed on aggregate-default-input devices.** macOS 26
  routes input through "CA default device aggregate" by default;
  samples reached the writer but our level-meter and per-device
  configuration assumed direct hardware. Filter aggregate devices
  out of the picker, unwrap them when resolving the system default.
- **Recorder panel "disappeared" intermittently on Fn press.**
  Aggressive `panel.keyDown { return }` override starved NSPanel
  lifecycle handling. Reverted to default `keyDown` and moved the
  synthetic-event filter to the CGEventTap, which is the
  architecturally correct intervention point.
- **Fn hotkey race on macOS 26 — "box appears, disappears, no audio."**
  `suppressEmojiPicker`'s synthetic F19 event, posted via
  `CGEventSource(.hidSystemState)`, began inheriting `.function` from the
  physically-held Fn on macOS 26. This tripped the combo-cancel handler
  and aborted every recording the moment it started. Fixed by switching
  the synth source to `.privateState`, explicitly clearing event flags,
  and sentinel-tagging the synthetic event via `eventSourceUserData` so
  our own handlers ignore it.
- **Race condition when stopping recording mid-capture.**
  `AudioRecordingService` could crash when `stopRecording` ran
  concurrently with the capture callback. Replaced the insufficient
  `isStopping` flag with a RosyWriter-style `RecordingStatus` enum; all
  writer-state mutation now happens on `audioQueue`.
- **"No audio" after rapid successive Fn presses.** The prior
  `.id(sessionID)` SwiftUI rebuild caused a subscription-timing race
  where `NotificationCenter` events fired before the new view's
  `.onReceive` subscription was live. Refactored to a
  `MiniRecorderViewModel` with `@ObservedObject`.
- **Escape-key handling in the mini recorder.** Removed the leaking
  `NSEvent` global/local monitors that double-fired alongside
  `KeyEventHandlerView`. Introduced `KeyableMiniRecorderPanel`
  (`canBecomeKey = true`) so `KeyEventHandlerView` becomes the sole
  Escape path.
- **Model download retry was unbounded.** Added
  `ModelDownloadService.maxDownloadAttempts = 2` and a `defer` for
  exactly-once `activeTasks` cleanup.
- **Force-unwrap crash risk** in `AIModel.recommendedModel` —
  `availableModels.last!` replaced with a guarded fallback.
- **Security-scoped resource leak** in `TranscribeAudioView` file-picker
  flow. Applied Apple's `defer` balance pattern, UUID-prefixed temp
  names, dropped the unsound fallback to a scoped URL whose access had
  already been released.
- **Audio playback failures were silent.** `AudioPlayerService.loadAudio`
  is now `async throws` and publishes `lastError` for SwiftUI observation.
- **License could revoke on transient network failures.** Only explicit
  server-confirmed invalid responses now deactivate; transport errors
  preserve cached trust (RevenueCat / StoreKit 2 pattern).
- **`WhisperService.loadModel` ignored task cancellation.** Added pre-
  and post-guards via `Task.checkCancellation()` plus a `defer` that
  guarantees `isLoading` resets on any exit path.
- **`ModelDownloadService.deleteModel` could match unrelated files.**
  Replaced substring `contains` matching with exact last-path-component
  equality; dropped `/tmp` and `~/.cache` paths.
- **`UpdateService` kept stale update banners after network errors.**
  Error path now nils `availableUpdate`; added `clearAvailableUpdate()`.
- **Audio-level meter could render invalid bars** if upstream ever
  produced a value outside [0, 1]. Added defensive clamp.
- **`HistoryService.deleteItem` could crash on stale `IndexSet` offsets**
  from rapid-delete UI races. Filters to in-range offsets before removal.

### Added

- **Stable self-signed dev identity (`SpeakType Dev`)** + `make
  setup-signing`. Keeps the binary's Designated Requirement constant
  across rebuilds so TCC grants (Accessibility, Microphone) survive a
  dev-loop rebuild. See `scripts/setup-dev-signing.sh`.
- **Unit test coverage (~140 tests)** for services and view models —
  concurrency safety, cancellation, state hygiene, error paths, the
  macOS 26 synthetic-event regression, transcript-cleanup contracts
  (Identity / FoundationModels / Claude / factory routing), and the
  NDJSON history store (round-trip, torn-line recovery, blank-line
  tolerance, format invariants).
- **`HistoryStore`** — actor-based NDJSON file persistence layer that
  replaces the UserDefaults history blob. Survives SIGKILL via atomic
  rewrites and `FileHandle.seekToEnd` appends.
- **`AXFocusedElementInspector`** — protocol-based AX preflight for
  paste eligibility, injectable for tests via `FocusedElementInspector`.
- **`MiniRecorderViewModel`** — session state moved off `@State` so the
  controller can drive it directly and SwiftUI owns the subscription
  lifecycle.
- **`AppDelegate.decideComboEvent`** — pure, testable extraction of the
  hotkey combo-cancel guard chain.
- **`KeyableMiniRecorderPanel`** — `canBecomeKey = true` NSPanel
  subclass so keyDown reaches the responder chain without pulling app
  focus.

### Changed

- **`AudioPlayerService` is now `@MainActor`** and `loadAudio(from:)` is
  `async throws`. Two call sites in History views updated accordingly.
- **`LicenseManager`** — added `isValidatingLicense` published flag for
  silent background validation UI.
- **Debug log** moved off `/tmp` to
  `~/Library/Application Support/SpeakType/Logs/debug.log`, gated behind
  `#if DEBUG`. Release builds use `print` (unified logging).
- **macOS deployment target unified at 14.0** across app and test
  targets; README badge updated. The upcoming FoundationModels code
  paths use `#available(macOS 26, *)` gates.
- **Dev-loop signing**: `SIGN_FLAGS` now threads through `make test` /
  `test-unit` / `test-ui` (was build-only), so test runs no longer
  fall back to ad-hoc signing and invalidate TCC grants. README
  documents using `make` over raw `xcodebuild` for local dev.
- **`BuildInfo.swift` no longer stamped on debug builds** — only
  release builds get a real timestamp; debug builds keep the committed
  `"development"` placeholder so the tracked file doesn't churn on
  every rebuild.
- **First-launch device default** is now `"system-default"` (sentinel
  in `selectedDeviceId`) instead of `availableDevices.first`. Existing
  user selections survive (selection isn't persisted across launches
  to begin with).

### Security

- Debug log no longer written to world-readable `/tmp`.

## [1.0.29] - 2026-03-24
- 

## [1.0.28] - 2026-03-22
- 

## [1.0.27] - 2026-03-22
- 

## [1.0.25] - 2026-03-21
- 

## [1.0.24] - 2026-03-12
- 

## [1.0.23] - 2026-02-27
- 

## [1.0.22] - 2026-02-27
- 

## [1.0.21] - 2026-02-17
- 

## [1.0.20] - 2026-02-17
- 

## [1.0.19] - 2026-02-16
- 

## [1.0.18] - 2026-02-16
- 

## [1.0.17] - 2026-02-16
- 

## [1.0.16] - 2026-02-15
- 

## [1.0.15] - 2026-02-15
- 

## [1.0.14] - 2026-02-15
- 

## [1.0.13] - 2026-02-15
- 

## [1.0.12] - 2026-02-15
- 

## [1.0.11] - 2026-02-15
- 

## [1.0.10] - 2026-02-14
- 

## [1.0.7] - 2026-02-03
- 

## [1.0.6] - 2026-02-03
- 

## [1.0.5] - 2026-01-27
- 
