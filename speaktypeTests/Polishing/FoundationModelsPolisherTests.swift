import XCTest
@testable import speaktype

#if canImport(FoundationModels)

/// Tests for FoundationModelsPolisher — the on-device Apple Intelligence
/// implementation of TranscriptPolisher.
///
/// Test surface is split into two layers:
///
/// 1. **Pure logic** (always runs): short-input bypass, empty-input
///    bypass, isAvailable resolves without crashing. These don't touch
///    the model so they're deterministic on any host.
///
/// 2. **Integration** (skipped when the model isn't ready): real polish
///    of a sample transcript with filler words. Requires macOS 26+,
///    Apple Intelligence enabled in System Settings, and the on-device
///    model already downloaded. `XCTSkipIf` keeps CI green on machines
///    without Apple Intelligence.
@available(macOS 26, *)
@MainActor
final class FoundationModelsPolisherTests: XCTestCase {

    // MARK: - Pure logic (always runs)

    func testShortInputBypassesModel() async throws {
        let polisher = FoundationModelsPolisher()
        // Under the bypass threshold (default 5 words). Model is never
        // invoked, so this passes regardless of Apple Intelligence
        // availability — and proves the bypass exists.
        let result = try await polisher.polish("hello there")
        XCTAssertEqual(result, "hello there",
            "Inputs under the word-count threshold must pass through unchanged " +
            "to avoid model hallucination on tiny prompts.")
    }

    func testEmptyInputReturnsEmpty() async throws {
        let polisher = FoundationModelsPolisher()
        let result = try await polisher.polish("")
        XCTAssertEqual(result, "")
    }

    func testWhitespaceOnlyInputReturnsUnchanged() async throws {
        let polisher = FoundationModelsPolisher()
        let result = try await polisher.polish("   \n\t  ")
        XCTAssertEqual(result, "   \n\t  ")
    }

    func testIsAvailableReturnsBoolWithoutCrashing() {
        // Just verify the property is reachable. The actual value is
        // host-dependent (true on a Mac with AI enabled, false on
        // EU pre-26.1 or non-AI-eligible hardware).
        _ = FoundationModelsPolisher.isAvailable
    }

    // MARK: - Integration (skipped when AI not available)

    func testRealPolishRemovesFillerWords() async throws {
        try XCTSkipIf(
            !FoundationModelsPolisher.isAvailable,
            "Apple Intelligence not available on this host — integration test skipped."
        )

        let polisher = FoundationModelsPolisher()
        let raw = "um so I think uh the meeting like went pretty well you know"
        let cleaned = try await polisher.polish(raw)

        // Don't over-assert exact output — model output can vary. Just
        // verify the obvious filler words are gone and the core
        // content survives.
        XCTAssertFalse(cleaned.lowercased().contains(" um "),
            "Cleaned output should not contain ' um ' filler.")
        XCTAssertFalse(cleaned.lowercased().contains(" uh "),
            "Cleaned output should not contain ' uh ' filler.")
        XCTAssertTrue(cleaned.lowercased().contains("meeting"),
            "Cleanup must preserve meaningful content (the word 'meeting' here).")
    }
}

#endif
