import XCTest
@testable import speaktype

/// Tests for High #5: force-unwrap in AIModel.recommendedModel().
/// Post-fix contract: the function must never force-unwrap; it returns a
/// real fallback model for any RAM value (including 0 or negative).
final class AIModelTests: XCTestCase {

    func testAvailableModelsIsNotEmpty() {
        // Structural invariant: the list must have at least one entry.
        // Without this, .last! in the old code would crash; post-fix we
        // still rely on non-emptiness for any sensible recommendation.
        XCTAssertFalse(AIModel.availableModels.isEmpty)
    }

    func testRecommendedModelForZeroRAMReturnsSmallestModel() {
        // Pre-fix: `availableModels.last!` — crash-prone if list empty.
        // Post-fix: returns a concrete fallback without force-unwrap.
        // We don't care which model, only that the call is safe and
        // returns a model whose minimumRAMGB is the smallest available.
        let model = AIModel.recommendedModel(forDeviceRAMGB: 0)
        let smallest = AIModel.availableModels.map(\.minimumRAMGB).min() ?? 0
        XCTAssertEqual(model.minimumRAMGB, smallest,
            "Zero-RAM device must fall back to the model with the smallest minimumRAMGB.")
    }

    func testRecommendedModelForNegativeRAMIsSafe() {
        // Defensive: negative RAM must not crash.
        let model = AIModel.recommendedModel(forDeviceRAMGB: -1)
        XCTAssertNotNil(model.variant)
    }

    func testRecommendedModelForAbundantRAMReturnsLargestFitting() {
        // Sanity: with plenty of RAM, pick the first (highest-tier) model.
        let model = AIModel.recommendedModel(forDeviceRAMGB: 1024)
        XCTAssertEqual(model.variant, AIModel.availableModels.first?.variant)
    }
}
