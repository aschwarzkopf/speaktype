import XCTest
@testable import speaktype

/// Tests for High #8: LicenseManager race where `isPro = true` is set
/// immediately from the Keychain cache before async validation completes,
/// with no UI signal and no distinction between "trusted cache" and
/// "validated". Post-fix contract: an `isValidatingLicense: Bool`
/// published flag is raised while the silent background validation runs,
/// and network failures do NOT deactivate — only explicit server-
/// confirmed invalid responses do.
@MainActor
final class LicenseManagerTests: XCTestCase {

    func testIsValidatingLicenseStartsFalse() {
        // Outside of an active validation, the flag must be false so UI
        // doesn't perpetually show a "verifying" state.
        let manager = LicenseManager.shared
        // Give any launch-time validation a moment to settle in case the
        // singleton was just constructed.
        XCTAssertFalse(manager.isValidatingLicense,
            "isValidatingLicense must default to false when no check is in progress.")
    }

    func testLicenseStateExposesValidatingFlag() {
        // Existence / access check: the property must be reachable from
        // SwiftUI bindings (i.e. exist on the type, be @Published).
        // This test will fail to compile until the property is added.
        let manager = LicenseManager.shared
        let _: Bool = manager.isValidatingLicense
    }
}
