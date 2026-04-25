import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// On-device transcript cleanup using Apple Intelligence's
/// FoundationModels framework (macOS 26+). Runs the small ~3B-parameter
/// language model that ships with Apple Intelligence — no network, no
/// cost, ~200–500 ms latency on M-series hardware.
///
/// The model session is created fresh per polish call so prior
/// transcripts don't leak into context (sessions retain conversation
/// history across `respond` calls).
///
/// Failures are designed to fall back gracefully: caller in
/// MiniRecorderView wraps with `try?`, so a guardrail violation,
/// context-window overflow, or unavailable model just means the user
/// gets the raw transcript instead. Cleanup never blocks paste.
@available(macOS 26, *)
struct FoundationModelsPolisher: TranscriptPolisher {

    /// Production system prompt. Tuned for high preservation: the model
    /// is biased toward keeping ambiguous words rather than cutting
    /// them, because "kept a real word" is a much better failure mode
    /// than "removed something the speaker meant."
    static let instructionsText = """
        You clean up voice-dictation transcripts. Remove filler words \
        (um, uh, ah, er, like, you know), collapse stutters (I-I-I → I), \
        and fix punctuation and capitalization. Do NOT rephrase, \
        summarize, or change meaning. Preserve the speaker's exact word \
        choice otherwise. If uncertain whether a word is filler, KEEP \
        it. Output only the cleaned transcript, no preamble.
        """

    /// Minimum word count for the model to be invoked at all. Below
    /// this threshold the input passes through unchanged — the model
    /// can hallucinate or over-edit on very short prompts (5-word
    /// snippets are a known failure pattern).
    static let minimumWordCount = 5

    /// True iff the on-device model is currently usable. False for
    /// devices without Apple Intelligence eligibility, regions where
    /// AI hasn't shipped, the user hasn't enabled AI, or the model
    /// hasn't finished its initial download.
    static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        default:
            return false
        }
    }

    func polish(_ raw: String) async throws -> String {
        // Bypass: trivial inputs pass through. Model invocation has
        // ~500ms first-call cost and risks hallucination on tiny
        // prompts — neither helpful for one-word transcriptions.
        let wordCount = raw
            .split(whereSeparator: { $0.isWhitespace })
            .count
        guard wordCount >= Self.minimumWordCount else { return raw }

        // Bypass: model isn't ready (offline-eligible, AI disabled,
        // model still downloading). Return raw rather than throwing —
        // the caller's `try?` would do the same fallback anyway.
        guard Self.isAvailable else { return raw }

        let session = LanguageModelSession(
            instructions: Instructions(Self.instructionsText)
        )

        do {
            let response = try await session.respond(to: Prompt(raw))
            let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Last-ditch sanity: if the model returned an empty string
            // (rare but possible under guardrail-edge cases), fall back
            // to raw rather than wiping the user's transcription.
            return cleaned.isEmpty ? raw : cleaned
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            // Sensitive content the model refuses to process. The user
            // still wants their transcript; return it raw.
            return raw
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // Long transcript blew past the ~4096-token window. Return
            // raw; we could chunk-and-rejoin in a future revision.
            return raw
        }
        // Other errors propagate — caller's try? in
        // MiniRecorderView.processRecording converts them to the
        // raw-fallback path.
    }
}

#endif
