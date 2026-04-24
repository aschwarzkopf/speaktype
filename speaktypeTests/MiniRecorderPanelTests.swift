import AppKit
import XCTest
@testable import speaktype

/// Tests for Critical #2: the new NSPanel subclass introduced to fix the
/// NSEvent-monitor leak + duplicate Escape handling. The fix replaces
/// ad-hoc global/local NSEvent monitors in MiniRecorderView with a
/// key-capable panel subclass so the existing KeyEventHandlerView receives
/// keyDown via the responder chain.
///
/// These tests are RED until `KeyableMiniRecorderPanel` is introduced in
/// MiniRecorderWindowController.swift and used in setupPanel().
@MainActor
final class MiniRecorderPanelTests: XCTestCase {

    private func makePanel() -> KeyableMiniRecorderPanel {
        KeyableMiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 50),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
    }

    func testPanelCanBecomeKey() {
        // The whole point of this subclass: a .nonactivatingPanel with
        // .borderless style will NOT become key by default, which means
        // keyDown never reaches the first responder — so Escape silently
        // fails. canBecomeKey MUST be overridden to true.
        let panel = makePanel()
        XCTAssertTrue(panel.canBecomeKey,
            "Panel must return canBecomeKey=true so keyDown events reach KeyEventHandlerView.")
    }

    func testPanelDoesNotBecomeMain() {
        // Nonactivating panels should not become main — that would pull
        // application focus away from the target app we're about to paste into.
        let panel = makePanel()
        XCTAssertFalse(panel.canBecomeMain,
            "Panel must not become main window — would steal focus from target app.")
    }

    func testPanelRetainsNonactivatingBehavior() {
        // Regression guard: the subclass must still be a nonactivating panel.
        let panel = makePanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }
}
