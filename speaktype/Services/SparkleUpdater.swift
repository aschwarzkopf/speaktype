import Combine
import Foundation
import Sparkle

/// Thin wrapper around Sparkle 2's `SPUStandardUpdaterController`.
/// Reads its feed URL and EdDSA public key from `Info.plist` (keys
/// `SUFeedURL` and `SUPublicEDKey`).
///
/// Sparkle handles the entire update lifecycle:
///   - Periodic checks against the appcast XML at SUFeedURL
///   - EdDSA signature verification of the downloaded ZIP
///   - Atomic in-place bundle replacement via Autoupdate.app helper
///   - Restart / install-on-quit logic
///   - Built-in standard UI (release notes window, "Install update"
///     dialog). Custom UI via SPUUserDriver can be added later.
///
/// AppDelegate creates the singleton on launch via
/// `SparkleUpdater.shared.start()` — the controller's underlying
/// `SPUUpdater` then schedules background checks based on
/// `SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` Info.plist
/// values.
///
/// SettingsView's "Check for Updates" button calls
/// `checkForUpdates()` on this facade; everything else is automatic.
@MainActor
final class SparkleUpdater: NSObject, ObservableObject {
    static let shared = SparkleUpdater()

    /// True once `start()` has been called and Sparkle's underlying
    /// updater is scheduling checks.
    @Published private(set) var isStarted: Bool = false

    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
    }

    /// Initialize Sparkle and begin scheduled update checks. Must be
    /// called on the main thread (Sparkle requires MainActor).
    /// Idempotent — repeated calls are no-ops.
    func start() {
        guard controller == nil else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        isStarted = true
    }

    /// User-initiated "Check for Updates…" trigger (Settings button,
    /// menu item, etc.). Shows Sparkle's standard UI: progress
    /// indicator, then either "you're up to date" or the update
    /// available dialog.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Whether the underlying updater is in a state that allows a
    /// user-initiated check. False during in-flight checks or while
    /// an install is staged. Useful for disabling a UI button.
    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// Date of the last successful update check, or nil if Sparkle
    /// hasn't completed one yet this launch.
    var lastUpdateCheckDate: Date? {
        controller?.updater.lastUpdateCheckDate
    }

    /// Public for tests / diagnostics. Reflects Sparkle's
    /// `automaticallyChecksForUpdates` runtime flag.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
