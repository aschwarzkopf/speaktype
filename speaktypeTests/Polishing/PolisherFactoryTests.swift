import XCTest
@testable import speaktype

/// Tests for PolisherFactory — the mode→polisher router.
///
/// In Phase 1 all three modes return IdentityPolisher (the rail is
/// wired, the implementations come later). Phase 2 will update the
/// `.local` expectation; Phase 3 will update the `.cloud` expectation.
/// The tests name exactly which mode they assert on so a failing test
/// points cleanly at the phase whose implementation hasn't landed.
final class PolisherFactoryTests: XCTestCase {

    func testOffReturnsIdentityPolisher() {
        let polisher = PolisherFactory.make(mode: .off)
        XCTAssertTrue(polisher is IdentityPolisher,
            "CleanupMode.off must always route to IdentityPolisher.")
    }

    @MainActor
    func testLocalRoutesToFoundationModelsWhenAvailableOtherwiseIdentity() {
        // Phase 2 contract: on macOS 26 with Apple Intelligence enabled,
        // `.local` resolves to FoundationModelsPolisher. On older macOS
        // or AI-disabled hosts, it falls back to IdentityPolisher so
        // the app still runs cleanly without local cleanup.
        let polisher = PolisherFactory.make(mode: .local)

        #if canImport(FoundationModels)
        if #available(macOS 26, *), FoundationModelsPolisher.isAvailable {
            XCTAssertTrue(polisher is FoundationModelsPolisher,
                "On macOS 26 with AI ready, .local must return FoundationModelsPolisher.")
            return
        }
        #endif
        XCTAssertTrue(polisher is IdentityPolisher,
            "Without Apple Intelligence available, .local falls back to IdentityPolisher.")
    }

    func testCloudReturnsIdentityPolisherInPhase1() {
        // Phase 3 will replace this with ClaudePolisher.
        let polisher = PolisherFactory.make(mode: .cloud)
        XCTAssertTrue(polisher is IdentityPolisher,
            "Phase 1 placeholder — Phase 3 replaces this with ClaudePolisher.")
    }

    // MARK: - CleanupMode enum contract

    func testCleanupModeAllCasesCoversOffLocalCloud() {
        // Locks in the enum's shape so a new case (e.g. .hybrid in the
        // future) doesn't silently go unrouted in PolisherFactory.
        XCTAssertEqual(Set(CleanupMode.allCases), [.off, .local, .cloud])
    }

    func testCleanupModeRawValuesAreStableStrings() {
        // @AppStorage("cleanupMode") stores the rawValue. Changing these
        // strings silently would wipe existing user preferences on
        // upgrade — lock the contract.
        XCTAssertEqual(CleanupMode.off.rawValue, "off")
        XCTAssertEqual(CleanupMode.local.rawValue, "local")
        XCTAssertEqual(CleanupMode.cloud.rawValue, "cloud")
    }
}
