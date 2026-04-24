import XCTest
@testable import speaktype

/// Tests for PasteEligibility — the AX preflight that gates auto-paste.
/// The real AX queries are in AXFocusedElementInspector and can't be
/// covered here without an actual frontmost app; instead we inject a
/// stub inspector and exercise the decision tree (allowlist bypass,
/// inspector consultation, nil-bundle handling).
final class PasteEligibilityTests: XCTestCase {

    private struct StubInspector: FocusedElementInspector {
        let result: Bool
        func acceptsText() -> Bool { result }
    }

    // MARK: - Inspector consultation

    func testReturnsTrueWhenInspectorAcceptsText() {
        let decision = PasteEligibility.canAutoPaste(
            inspector: StubInspector(result: true),
            frontmostBundleID: "com.example.some-random-app"
        )
        XCTAssertTrue(decision)
    }

    func testReturnsFalseWhenInspectorDoesNotAcceptText() {
        let decision = PasteEligibility.canAutoPaste(
            inspector: StubInspector(result: false),
            frontmostBundleID: "com.example.some-random-app"
        )
        XCTAssertFalse(decision,
            "Non-editable focus on a non-allowlisted app must return false " +
            "so the caller skips Cmd+V and avoids the NSBeep regression.")
    }

    // MARK: - Bundle-ID allowlist bypass

    func testAllowlistedBundleBypassesInspector() {
        // Warp terminal reports no usable AX role for its text surface
        // but paste reliably works. The allowlist must override a
        // false inspector result.
        let decision = PasteEligibility.canAutoPaste(
            inspector: StubInspector(result: false),
            frontmostBundleID: "dev.warp.Warp-Stable"
        )
        XCTAssertTrue(decision,
            "Warp is on the allowlist — paste must be attempted even when " +
            "AX inspection says no.")
    }

    func testAllowlistedBundleStillReturnsTrueWhenInspectorAgrees() {
        // Sanity: allowlisted + inspector says yes → still yes.
        let decision = PasteEligibility.canAutoPaste(
            inspector: StubInspector(result: true),
            frontmostBundleID: "dev.warp.Warp-Stable"
        )
        XCTAssertTrue(decision)
    }

    // MARK: - Edge cases

    func testNilBundleIDDefersToInspector() {
        // If we can't identify the frontmost app, the allowlist can't
        // apply — fall through to whatever the inspector says.
        let decisionYes = PasteEligibility.canAutoPaste(
            inspector: StubInspector(result: true),
            frontmostBundleID: nil
        )
        XCTAssertTrue(decisionYes)

        let decisionNo = PasteEligibility.canAutoPaste(
            inspector: StubInspector(result: false),
            frontmostBundleID: nil
        )
        XCTAssertFalse(decisionNo)
    }

    // MARK: - Allowlist contents

    func testAllowlistContainsWarp() {
        // Locks in that Warp stays on the allowlist. Research flagged
        // it as a known false-negative for role-based AX checks.
        XCTAssertTrue(PasteEligibility.forceAllowedBundleIDs.contains("dev.warp.Warp-Stable"))
    }

    func testAllowlistDoesNotContainArbitraryApp() {
        // Regression guard — the allowlist should stay small and
        // explicit.
        XCTAssertFalse(PasteEligibility.forceAllowedBundleIDs.contains("com.apple.TextEdit"),
            "TextEdit should NOT be allowlisted — AX role-check handles it cleanly. " +
            "Only apps with genuinely broken AX belong on the bypass list.")
    }
}
