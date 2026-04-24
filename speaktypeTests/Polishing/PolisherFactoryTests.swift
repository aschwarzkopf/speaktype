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

    func testLocalReturnsIdentityPolisherInPhase1() {
        // Phase 2 will replace this with FoundationModelsPolisher. Until
        // then, .local is a safe no-op so the rail can be wired through
        // processRecording without changing behavior.
        let polisher = PolisherFactory.make(mode: .local)
        XCTAssertTrue(polisher is IdentityPolisher,
            "Phase 1 placeholder — Phase 2 replaces this with FoundationModelsPolisher.")
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
