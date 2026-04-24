import Cocoa
import SwiftUI

/// Nonactivating panel that is still allowed to become key — without this,
/// a borderless `.nonactivatingPanel` never becomes first responder and
/// keyDown events (e.g. Escape) never reach our KeyEventHandlerView.
/// canBecomeMain stays false so the panel does not steal focus from the
/// target app the user is about to paste into.
final class KeyableMiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // No keyDown override. The synthetic-F19 sentinel filter lives in
    // AppDelegate.handleHotkeyEventTap at the CGEventTap level, which
    // drops sentinel-tagged events from the stream before any NSEvent is
    // ever created for them. That is the architecturally correct point —
    // the CGEvent's user-data field is reliable at the tap (unlike
    // NSEvent.cgEvent, which returns a reconstructed event whose user-
    // data can read back as zero on keyDown). Overriding keyDown here
    // additionally starved NSPanel lifecycle handling (Cmd-W, cancel
    // operation, responder-chain forwarding), which caused a separate
    // "panel disappears" regression.
}

@MainActor
class MiniRecorderWindowController: NSObject {
    private var panel: KeyableMiniRecorderPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var lastActiveApp: NSRunningApplication?

    /// The view model that drives MiniRecorderView. The controller mutates
    /// it directly instead of posting notifications — this eliminates the
    /// subscription-timing race in the old NotificationCenter + `.id()`
    /// rebuild design. Exposed `let` so SwiftUI observes via @ObservedObject
    /// and tests can assert on state transitions.
    let viewModel = MiniRecorderViewModel()

    /// Back-compat accessor — existing call sites used `currentSessionID`.
    var currentSessionID: UUID { viewModel.sessionID }

    override init() {
        super.init()
        viewModel.onCommit = { [weak self] text in
            self?.handleCommit(text: text)
        }
        viewModel.onCancel = { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    // MARK: - Session control

    func startRecording() {
        lastActiveApp = NSWorkspace.shared.frontmostApplication

        // Play the "listening" tone as soon as the hotkey fires, so the
        // user gets confirmation before the panel even finishes animating.
        FeedbackSoundPlayer.shared.playStart()

        if panel == nil {
            setupPanel()
        }

        guard let panel = panel else { return }

        if !panel.isVisible {
            print("Showing Mini Recorder Panel")
            panel.layoutIfNeeded()

            if let screen = NSScreen.main {
                let visibleFrame = screen.visibleFrame
                let windowWidth: CGFloat = 140
                let x = visibleFrame.midX - (windowWidth / 2)
                let y = visibleFrame.minY + 50
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                panel.center()
            }

            panel.orderFrontRegardless()
            panel.makeKey()
        }

        // Drive the VM — the observing SwiftUI view reacts via
        // .onChange(of: pendingAction). No notification race because
        // @Published subscriptions are attached by SwiftUI before the
        // mutation is observed.
        viewModel.startSession()
    }

    func stopRecording() {
        viewModel.requestStop()
    }

    func cancelRecording() {
        viewModel.requestCancel()
    }

    // MARK: - Setup

    private func setupPanel() {
        let recorderView = MiniRecorderView(viewModel: viewModel)
            .background(Color.clear)

        hostingController = NSHostingController(rootView: AnyView(recorderView))

        let p = KeyableMiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 30),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        p.isOpaque = false
        p.backgroundColor = .clear
        p.contentViewController = hostingController

        if let hostView = hostingController?.view {
            hostView.wantsLayer = true
            hostView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.hasShadow = false

        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        self.panel = p
    }

    // MARK: - Commit flow

    private func handleCommit(text: String) {
        // Play the "commit" tone — slightly lower pitch than playStart
        // so the up→down interval signals the action completed.
        FeedbackSoundPlayer.shared.playStop()

        Task {
            ClipboardService.shared.copy(text: text)

            await MainActor.run {
                self.panel?.orderOut(nil)
            }

            let accessibilityTrusted = ClipboardService.shared.isAccessibilityTrusted

            if !accessibilityTrusted {
                print(
                    "⚠️ Accessibility not granted - text copied to clipboard, user can paste with Cmd+V"
                )
                return
            }

            if let app = self.lastActiveApp {
                _ = await MainActor.run {
                    app.activate()
                }
                // Wait until the target app is actually frontmost before
                // posting Cmd+V. Fixed sleeps are race-prone — if Cmd+V
                // arrives while our panel is still resigning key (or
                // during the brief limbo where no window is key), the
                // synthetic keyDown lands at NSResponder.noResponder(for:)
                // which beeps by design. Observing activation is
                // deterministic where a fixed sleep is statistical.
                await Self.waitForApplicationActivation(
                    bundleID: app.bundleIdentifier,
                    timeout: 1.0
                )
            }

            await MainActor.run {
                if PasteEligibility.canAutoPaste() {
                    ClipboardService.shared.paste()
                } else {
                    // No editable element has focus — posting Cmd+V
                    // would produce NSBeep via noResponder(for: paste:).
                    // Skip the paste; text is on the clipboard so the
                    // user can still paste manually when ready.
                    // (A user-facing HUD lives in git history; add back
                    // when the UI design work happens.)
                    print("ℹ️ No editable focus — skipping auto-paste, text on clipboard")
                }
            }
        }
    }

    /// Wait for the application with `bundleID` to become frontmost,
    /// returning as soon as it does (or after `timeout` seconds,
    /// whichever is first). Observes
    /// `NSWorkspace.didActivateApplicationNotification`; no polling.
    private static func waitForApplicationActivation(
        bundleID: String?,
        timeout: TimeInterval
    ) async {
        // Already there — nothing to wait for.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let workspace = NSWorkspace.shared
            let center = workspace.notificationCenter
            let lock = NSLock()
            var resumed = false
            var observer: NSObjectProtocol?

            let resumeOnce: () -> Void = {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                if let observer = observer {
                    center.removeObserver(observer)
                }
                continuation.resume()
            }

            observer = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    app.bundleIdentifier == bundleID
                {
                    resumeOnce()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                resumeOnce()
            }
        }
    }
}
