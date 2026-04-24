import XCTest
@testable import speaktype

/// Tests for Medium #11: UpdateService stale-state hygiene.
/// Post-fix contract: on network failure during `checkForUpdates`,
/// `availableUpdate` is cleared rather than left as a potentially stale
/// value from a prior successful check.
@MainActor
final class UpdateServiceTests: XCTestCase {

    func testCheckingFlagResetsAfterInvocation() async {
        let service = UpdateService.shared
        // Regardless of network outcome (which we can't mock here without
        // dependency injection), the flag must be false once the call
        // completes — the test simply waits and checks.
        await service.checkForUpdates(silent: true)
        XCTAssertFalse(service.isCheckingForUpdates,
            "isCheckingForUpdates must be false after checkForUpdates returns.")
    }

    func testClearStaleUpdateExposedForRecovery() {
        // The post-fix introduces a `clearAvailableUpdate()` method (or
        // equivalent hook) so the error path in checkForUpdates can
        // explicitly discard previous results. We verify the public
        // surface exists.
        let service = UpdateService.shared
        service.clearAvailableUpdate()
        XCTAssertNil(service.availableUpdate,
            "clearAvailableUpdate() must null the published availableUpdate.")
    }
}
