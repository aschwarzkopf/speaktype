import XCTest
@testable import speaktype

/// Tests for the SparkleUpdater facade. The real Sparkle library does
/// the heavy lifting (network, signature verification, install) and
/// can't be unit-tested without a real appcast feed, so coverage here
/// is limited to the facade's public surface and lifecycle invariants.
@MainActor
final class SparkleUpdaterTests: XCTestCase {

    func testSingletonAccessible() {
        XCTAssertNotNil(SparkleUpdater.shared)
    }

    func testIsStartedReflectsLifecycle() {
        // Singleton is process-wide; start() may already have been
        // called by AppDelegate during the test target's app launch.
        // Either way, the property must be readable without crashing.
        let _ = SparkleUpdater.shared.isStarted
    }

    func testStartIsIdempotent() {
        let updater = SparkleUpdater.shared
        // Multiple start() calls must not crash and must not produce
        // multiple Sparkle controllers (would result in duplicate
        // checks / overlapping UIs).
        updater.start()
        let firstStartedState = updater.isStarted
        updater.start()
        XCTAssertEqual(updater.isStarted, firstStartedState,
            "Repeated start() calls must be safe no-ops once started.")
    }

    func testCanCheckForUpdatesIsBool() {
        // Just verify the property is reachable. Actual value depends
        // on Sparkle's internal state (network availability, ongoing
        // checks, etc.).
        let _: Bool = SparkleUpdater.shared.canCheckForUpdates
    }

    func testInfoPlistContainsSparkleConfiguration() {
        // Fail loudly if anyone removes the Info.plist Sparkle keys —
        // without them Sparkle silently does nothing.
        let bundle = Bundle(for: SparkleUpdater.self)
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String

        XCTAssertNotNil(feedURL,
            "SUFeedURL is required in Info.plist for Sparkle to know where to look.")
        XCTAssertNotNil(publicKey,
            "SUPublicEDKey is required in Info.plist for EdDSA verification.")

        if let feedURL {
            XCTAssertTrue(feedURL.hasPrefix("https://"),
                "SUFeedURL must be HTTPS — Sparkle refuses HTTP feeds.")
            XCTAssertTrue(feedURL.hasSuffix(".xml") || feedURL.contains("appcast"),
                "SUFeedURL should point to an appcast XML.")
        }

        if let publicKey {
            // EdDSA public keys are 32 bytes; base64-encoded that's
            // 44 characters (with padding) or 43 (without).
            XCTAssertGreaterThanOrEqual(publicKey.count, 43,
                "SUPublicEDKey looks malformed — base64-encoded EdDSA pubkeys are ~44 chars.")
        }
    }
}
