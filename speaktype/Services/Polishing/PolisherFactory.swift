import Foundation

/// User-facing transcript-cleanup mode. Persisted via `@AppStorage`
/// using the rawValue strings — DO NOT change the strings without a
/// migration; doing so silently wipes existing user preferences.
enum CleanupMode: String, CaseIterable {
    case off
    case local
    case cloud
}

/// Routes a `CleanupMode` to a concrete `TranscriptPolisher`.
///
/// In Phase 1 all three modes resolve to `IdentityPolisher` — the rail
/// is wired through `MiniRecorderView.processRecording` so that
/// turning the dial via @AppStorage changes which implementation is
/// invoked, but no observable behavior changes yet. Phase 2 swaps
/// `.local` to `FoundationModelsPolisher`; Phase 3 swaps `.cloud` to
/// `ClaudePolisher`.
///
/// This factory is the single seam where mode→implementation routing
/// happens. Callers should never construct polishers directly; they
/// should always go through `make(mode:)` so the seam stays clean.
enum PolisherFactory {
    static func make(mode: CleanupMode) -> TranscriptPolisher {
        switch mode {
        case .off:   return IdentityPolisher()
        case .local: return IdentityPolisher()  // Phase 2: FoundationModelsPolisher
        case .cloud: return IdentityPolisher()  // Phase 3: ClaudePolisher
        }
    }
}
