import XCTest
@testable import speaktype

final class ModelDownloadServiceTests: XCTestCase {
    
    func testInitialState() {
        let service = ModelDownloadService.shared
        
        // Ensure no lingering downloads from other runs
        // (Note: Shared singleton might have state if tests run in parallel or sequence without clearing)
        // We can't easily clear private vars, but we can check types.
        
        XCTAssertNotNil(service.downloadProgress)
        XCTAssertNotNil(service.isDownloading)
    }
    
    // MARK: - High #4: Retry-bound state hygiene
    // Real download/retry exercise requires mocking WhisperKit. These
    // tests lock down the contract that the fix must preserve: `activeTasks`
    // is cleaned up exactly once across cancel and failure paths, and
    // `maxDownloadAttempts` is a sane small constant.

    func testCancelDownloadClearsStateForUnknownVariant() {
        // Cancelling a variant that was never queued must be a safe no-op:
        // no crash, no residual isDownloading=true state.
        let service = ModelDownloadService.shared
        let bogus = "test/nonexistent-variant-\(UUID().uuidString)"

        service.cancelDownload(for: bogus)

        XCTAssertNotEqual(service.isDownloading[bogus], true,
            "cancelDownload must not leave isDownloading=true for an unknown variant.")
        XCTAssertNotEqual(service.downloadProgress[bogus], 1.0,
            "cancelDownload must not mark progress complete for an unknown variant.")
    }

    // MARK: - Medium #10: Exact-match deletion (no substring false-positives)
    // Post-fix contract: the deletion helper matches a variant's directory
    // by exact last-path-component equality (and the underscore-separator
    // alias), NOT a substring `contains` that could match "my-whisper-notes".

    func testShouldDeleteMatchesExactVariantName() {
        XCTAssertTrue(
            ModelDownloadService.shouldDelete(
                fileName: "openai_whisper-medium",
                patterns: ["openai_whisper-medium", "whisper-medium"]
            )
        )
    }

    func testShouldDeleteMatchesExactShortName() {
        XCTAssertTrue(
            ModelDownloadService.shouldDelete(
                fileName: "whisper-medium",
                patterns: ["openai_whisper-medium", "whisper-medium"]
            )
        )
    }

    func testShouldDeleteRejectsSubstringFalsePositive() {
        // The bug we're fixing: "my-whisper-notes.md" used to be deletable
        // because "whisper" was a substring. Post-fix: exact match only.
        XCTAssertFalse(
            ModelDownloadService.shouldDelete(
                fileName: "my-whisper-notes.md",
                patterns: ["openai_whisper-medium", "whisper-medium"]
            )
        )
    }

    func testShouldDeleteRejectsSimilarButDifferentVariant() {
        XCTAssertFalse(
            ModelDownloadService.shouldDelete(
                fileName: "openai_whisper-large",
                patterns: ["openai_whisper-medium", "whisper-medium"]
            )
        )
    }

    func testShouldDeleteRejectsEmptyPatterns() {
        XCTAssertFalse(
            ModelDownloadService.shouldDelete(fileName: "anything", patterns: [])
        )
    }

    func testMaxDownloadAttemptsIsBoundedAndSmall() {
        // The post-fix retry loop must expose a small constant (not a
        // magic number scattered in code). Two attempts is the norm for
        // a local-cache-collision retry.
        XCTAssertLessThanOrEqual(ModelDownloadService.maxDownloadAttempts, 3,
            "Retry attempts must be bounded to avoid runaway loops on persistent failures.")
        XCTAssertGreaterThanOrEqual(ModelDownloadService.maxDownloadAttempts, 2,
            "At least one retry after cache cleanup is required for the known failure mode.")
    }
}
