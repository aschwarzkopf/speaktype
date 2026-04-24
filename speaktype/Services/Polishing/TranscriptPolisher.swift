import Foundation

/// Post-processing pass that turns a raw Whisper transcript into a
/// cleaned final string — removing filler words, collapsing stutters,
/// fixing punctuation. Implementations include a pass-through (Off),
/// an on-device FoundationModels variant (Local), and a Claude API
/// variant (Cloud); they all share this protocol so callers can swap
/// providers without changing wiring.
///
/// Implementations MUST be safe to call from `MainActor` (the recorder
/// pipeline awaits results on main). They MAY throw — caller fallback
/// is expected to be `try? await polish(...) ?? raw`, so transient
/// failures never block the user's paste flow.
protocol TranscriptPolisher {
    func polish(_ raw: String) async throws -> String
}

/// No-op polisher. Returns its input unchanged, byte-for-byte. Used:
///   1. When `CleanupMode == .off` — the user wants the raw transcript.
///   2. As the Phase-1 placeholder for `.local` and `.cloud` until the
///      real FoundationModels and Claude implementations land.
///
/// The contract is strict: this implementation is NOT allowed to trim,
/// normalize, or alter the string in any way. That's the real
/// polishers' job, and the factory falls back to this implementation
/// for modes whose real code isn't yet wired up — silently mutating
/// here would mask bugs in those future implementations.
struct IdentityPolisher: TranscriptPolisher {
    func polish(_ raw: String) async throws -> String { raw }
}
