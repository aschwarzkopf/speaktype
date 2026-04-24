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

        if panel == nil {
            setupPanel()
        }

        guard let panel = panel else { return }

        if !panel.isVisible {
            print("Showing Mini Recorder Panel")
            panel.layoutIfNeeded()

            if let screen = NSScreen.main {
                let visibleFrame = screen.visibleFrame
                let windowWidth: CGFloat = 260
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
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 50),
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
            }

            try? await Task.sleep(nanoseconds: 500_000_000)

            await MainActor.run {
                ClipboardService.shared.paste()
            }
        }
    }
}
