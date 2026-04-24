# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

### Fixed

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
- **Unit test coverage (68 tests)** for services and view models —
  concurrency safety, cancellation, state hygiene, error paths, and the
  macOS 26 synthetic-event regression.
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
