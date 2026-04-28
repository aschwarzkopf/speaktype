import XCTest
@testable import speaktype

@MainActor
final class WhisperServiceTests: XCTestCase {
    
    var service: WhisperService?
    
    override func setUpWithError() throws {
        service = WhisperService()
    }

    override func tearDownWithError() throws {
        // Rely on automatic deallocation
    }

    func testDefaultInitialization() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isInitialized)
        XCTAssertEqual(service.currentModelVariant, "")
    }
    
    // Note: detailed loadModel tests require mocking the WhisperKit dependency
    // which is external. We test the state management around it.
    
    func testStateFlags() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isTranscribing)
        // Simulate transcription start
        service.isTranscribing = true
        XCTAssertTrue(service.isTranscribing)
    }

    func testNormalizedTranscriptionRemovesBlankAudioPlaceholders() {
        let normalized = WhisperService.normalizedTranscription(
            from: " [BLANK_AUDIO]  hello   <|nospeech|> [SILENCE] "
        )

        XCTAssertEqual(normalized, "hello")
    }

    func testNormalizedTranscriptionRemovesBracketedNoiseLabels() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind blowing] (heartbeat) answer [S]"
        )

        XCTAssertEqual(normalized, "answer")
    }

    func testNormalizedTranscriptionRemovesNoiseOnlyArtifacts() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind] (Loud noise) (indistinct)"
        )

        XCTAssertEqual(normalized, "")
    }

    // MARK: - Whisper end-of-audio hallucination filtering
    // Whisper trained heavily on YouTube videos with closing phrases
    // ("Thanks for watching", "Please subscribe", etc.) and reproduces
    // them on silent / trailing-silence audio. Filter the standalone
    // case to empty (signals "no speech" downstream) and strip the
    // trailing case when there's substantive content before it.

    // Standalone hallucinations → empty

    func testStandaloneThankYouReturnsEmpty() {
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Thank you."), "")
    }

    func testStandaloneThanksReturnsEmpty() {
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Thanks"), "")
    }

    func testStandaloneSubscribeReturnsEmpty() {
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Please subscribe."), "")
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Like and subscribe"), "")
    }

    func testStandaloneSeeYouNextTimeReturnsEmpty() {
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "See you next time."), "")
    }

    func testStandaloneByeReturnsEmpty() {
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Bye-bye"), "")
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Goodbye."), "")
    }

    func testJustPunctuationReturnsEmpty() {
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "."), "")
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "..."), "")
    }

    // Trailing hallucinations with substantive content → strip the trailing

    func testTrailingThankYouStrippedWhenContentBefore() {
        let raw = "We discussed the project timeline and next steps for the launch. Thank you."
        let cleaned = WhisperService.normalizedTranscription(from: raw)
        XCTAssertFalse(cleaned.lowercased().hasSuffix("thank you."),
            "Trailing 'Thank you.' must be stripped when there's real content before it.")
        XCTAssertTrue(cleaned.lowercased().contains("project timeline"),
            "Substantive content before the hallucination must be preserved.")
    }

    func testTrailingSubscribeStrippedWhenContentBefore() {
        let raw = "I went over the budget items and reviewed the new hire pipeline. Please subscribe."
        let cleaned = WhisperService.normalizedTranscription(from: raw)
        XCTAssertFalse(cleaned.lowercased().contains("subscribe"))
    }

    // Negative cases — must NOT strip legitimate uses

    func testLegitimateThanksMidSentencePreserved() {
        // "Thank you" used as part of natural speech — has substantive
        // content AFTER the phrase, so it's not at the trailing position.
        let raw = "I told her thank you for the help with the parking pass"
        let cleaned = WhisperService.normalizedTranscription(from: raw)
        XCTAssertEqual(cleaned, raw,
            "'Thank you' embedded in normal speech must survive — it's only " +
            "stripped at the very end of the transcript.")
    }

    func testLegitimateThanksAtEndPreservedWhenShortPrefix() {
        // Very short prefix means we can't safely classify the trailing
        // phrase as hallucination. Better to keep it than risk cutting
        // legitimate content. (User: "Hi! Thanks.")
        let raw = "Hi! Thanks."
        let cleaned = WhisperService.normalizedTranscription(from: raw)
        XCTAssertTrue(cleaned.lowercased().contains("thanks"),
            "Don't strip trailing 'Thanks' when prefix is too short to confidently " +
            "classify as hallucination.")
    }

    func testNormalTranscriptUnchanged() {
        let raw = "We covered the agenda items and assigned action items to each team lead"
        XCTAssertEqual(WhisperService.normalizedTranscription(from: raw), raw)
    }

    func testCaseInsensitiveMatching() {
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "thank you"), "")
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "THANK YOU"), "")
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Thank You."), "")
    }

    // MARK: - Medium #9: Task cancellation hygiene
    // Post-fix contract: loadModel honors cooperative cancellation. A
    // task that is cancelled before loadModel reaches its first await
    // must throw CancellationError rather than perform the expensive
    // WhisperKit init.
    func testLoadModelThrowsCancellationErrorWhenPreCancelled() async {
        guard let service = service else { return XCTFail("Service should be initialized") }

        let task = Task {
            try await service.loadModel(variant: "openai_whisper-tiny")
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("loadModel must throw after cancellation instead of completing.")
        } catch is CancellationError {
            // Expected — the pre-cancel check fired before the heavy init.
        } catch {
            // Either CancellationError or a swift error whose localization says cancelled.
            XCTAssertTrue(
                (error as NSError).localizedDescription.localizedCaseInsensitiveContains("cancel")
                    || error is CancellationError,
                "Expected cancellation-shaped error, got \(error)"
            )
        }

        // State hygiene: after a cancelled load, the service must not claim
        // to be initialized on the cancelled variant.
        XCTAssertFalse(service.isInitialized && service.currentModelVariant == "openai_whisper-tiny",
            "A cancelled loadModel must not leave the service in an initialized state for that variant.")
        XCTAssertFalse(service.isLoading,
            "isLoading must return to false after cancellation so future loads aren't blocked.")
    }
}
