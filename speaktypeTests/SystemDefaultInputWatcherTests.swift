import AVFoundation
import XCTest
@testable import speaktype

/// Tests for SystemDefaultInputWatcher — the Core Audio observer that
/// tracks the system's default input device and publishes its UID and
/// localized name for UI subtitles and AudioRecordingService to follow.
///
/// The Core Audio listener itself fires on arbitrary audio threads and
/// can't be exercised deterministically from a unit test (would need a
/// real default-device change event). What we CAN cover:
///
/// 1. The static resolver — returns UID+name on a system with a mic,
///    nil on a system without one.
/// 2. The watcher singleton is reachable and its published state is
///    consistent with the static resolver at init time.
/// 3. The sentinel string used by AudioRecordingService is stable.
@MainActor
final class SystemDefaultInputWatcherTests: XCTestCase {

    func testSingletonIsAccessible() {
        let watcher = SystemDefaultInputWatcher.shared
        XCTAssertNotNil(watcher)
    }

    func testInitialStateMatchesStaticResolver() {
        let watcher = SystemDefaultInputWatcher.shared
        let (resolvedUID, resolvedName) = SystemDefaultInputWatcher.resolveDefaultInput()

        // If the host has a default input (normal dev Mac), both paths
        // should agree. If there's no mic (CI with no audio hardware),
        // both should be nil. Either way they should match.
        XCTAssertEqual(watcher.currentDefaultUID, resolvedUID,
            "Watcher's published UID must match the static resolver on init. " +
            "Mismatch means init missed the initial refresh.")
        XCTAssertEqual(watcher.currentDefaultDeviceName, resolvedName)
    }

    func testResolverReturnsConsistentValuesAcrossCalls() {
        // Called twice in rapid succession — no hardware change means
        // both results must match. Catches flaky Core Audio errors
        // (e.g. size-buffer overflow, property-not-settable).
        let (uid1, name1) = SystemDefaultInputWatcher.resolveDefaultInput()
        let (uid2, name2) = SystemDefaultInputWatcher.resolveDefaultInput()
        XCTAssertEqual(uid1, uid2)
        XCTAssertEqual(name1, name2)
    }

    func testResolverReturnsNilPairWhenNoDeviceOrValidUIDStringOtherwise() {
        let (uid, _) = SystemDefaultInputWatcher.resolveDefaultInput()

        if let uid = uid {
            // Valid UID should be non-empty and a real String.
            XCTAssertFalse(uid.isEmpty)
            // Core Audio UIDs are typically formatted like
            // "BuiltInMicrophoneDevice" or "AppleHDAEngineInput:..."
            // but we don't want to over-assert structure.
        } else {
            // No device → both parts should be nil (not a half-resolved state).
            let (_, name) = SystemDefaultInputWatcher.resolveDefaultInput()
            XCTAssertNil(name,
                "If UID is nil, name must also be nil — no half-resolved states.")
        }
    }

    // MARK: - Sentinel contract

    func testSystemDefaultSentinelIsStable() {
        // AudioRecordingService uses this string in UserDefaults as the
        // "follow system default" marker. Changing it silently would
        // wipe every user's preference on upgrade.
        XCTAssertEqual(AudioRecordingService.systemDefaultSentinel, "system-default")
    }
}
