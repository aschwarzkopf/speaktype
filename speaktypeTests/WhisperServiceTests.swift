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
