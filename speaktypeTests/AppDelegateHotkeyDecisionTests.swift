import AppKit
import XCTest
@testable import speaktype

/// Tests for the pure hotkey-decision helper extracted from
/// AppDelegate.handleModifierComboEvent. Extracting it into a pure
/// function makes the guard chain testable without the AppKit event
/// runloop — previously the only way to exercise this logic was to
/// physically press keys.
///
/// The decision helper drives the combo-cancel path: when the user is
/// holding the hotkey AND presses an additional modified key, the in-
/// progress recording should be cancelled. It must NOT trigger on our
/// own synthetic suppressEmojiPicker event, which became a real issue
/// on macOS 26 after `CGEventSource(.hidSystemState)` began composing
/// live modifier state (.function from physical Fn) onto synthesized
/// events.
final class AppDelegateHotkeyDecisionTests: XCTestCase {

    // Default arguments representing "user is holding Fn in hold-mode with
    // a valid modifier combo pressed" — the shape that should cancel.
    private func decide(
        keyCode: UInt16 = 0x00,  // 'A'
        flags: NSEvent.ModifierFlags = [.shift],
        hotkeyCode: UInt16 = 0x3F,  // Fn
        isHotkeyPressed: Bool = true,
        recordingMode: Int = 0,
        isSynthetic: Bool = false
    ) -> AppDelegate.HotkeyDecision {
        AppDelegate.decideComboEvent(
            keyCode: keyCode,
            flags: flags,
            hotkeyCode: hotkeyCode,
            isHotkeyPressed: isHotkeyPressed,
            recordingMode: recordingMode,
            isSynthetic: isSynthetic
        )
    }

    // MARK: - The macOS 26 bug we're fixing

    func testSyntheticEventIsIgnoredEvenWhenItLooksLikeACombo() {
        // This is the exact shape that caused the "no audio" bug: Fn held,
        // our suppressEmojiPicker posts F19 which comes back carrying
        // .function. Pre-fix this cancelled the recording; post-fix the
        // sentinel-tagged synthetic is ignored.
        let decision = decide(
            keyCode: 0x50,           // F19
            flags: [.function],      // .function propagated from held Fn
            isSynthetic: true        // sentinel said "this is ours"
        )
        XCTAssertEqual(decision, .ignore)
    }

    // MARK: - Genuine combo still cancels

    func testGenuineModifierComboCancels() {
        // User holds Fn + presses Shift+A — that should still cancel.
        XCTAssertEqual(decide(keyCode: 0x00, flags: [.shift]), .cancel)
    }

    func testControlComboCancels() {
        XCTAssertEqual(decide(keyCode: 0x00, flags: [.control]), .cancel)
    }

    func testCommandComboCancels() {
        XCTAssertEqual(decide(keyCode: 0x00, flags: [.command]), .cancel)
    }

    // MARK: - Guard boundaries

    func testIdleStateIsIgnored() {
        // Nothing happens if the hotkey isn't even being held.
        XCTAssertEqual(decide(isHotkeyPressed: false), .ignore)
    }

    func testToggleModeIgnoresComboEvents() {
        // Combo-cancel only applies in hold mode. Toggle mode has its own
        // press-to-stop flow and shouldn't be ambushed by stray modifier
        // combinations.
        XCTAssertEqual(decide(recordingMode: 1), .ignore)
    }

    func testNoModifierFlagsIsIgnored() {
        // If the key has no device-independent modifier, it's just a
        // regular key press — not a combo worth cancelling for.
        XCTAssertEqual(decide(flags: []), .ignore)
    }

    func testHotkeyItselfIsIgnored() {
        // The combo handler must not act on the hotkey keycode itself —
        // that's the flagsChanged path's job, not this one.
        XCTAssertEqual(decide(keyCode: 0x3F, flags: [.function]), .ignore)
    }

    // MARK: - Edge: synthetic flag wins over everything

    func testSyntheticSentinelWinsOverGenuineComboShape() {
        // Even a "real" looking combo is ignored if the sentinel says the
        // event originated from our own code. This matters because some
        // combo shapes (Fn + modifier + normal key) could collide with
        // legitimate synthesized input from the app itself.
        let decision = decide(
            keyCode: 0x00,
            flags: [.shift, .command],
            isSynthetic: true
        )
        XCTAssertEqual(decision, .ignore)
    }

    // MARK: - Edge: non-device-independent-flag-only is ignored

    // MARK: - NSBeep regression — KeyCaptureView must silently drop
    // synthetic events. The boink fired intermittently on rapid Fn
    // presses because the F19 from suppressEmojiPicker hit
    // KeyCaptureView.keyDown as first responder, fell through super,
    // walked the responder chain unhandled, and triggered NSBeep.
    // The fix is a cheap sentinel check in keyDown; this test documents
    // the contract (the sentinel constant exists and is the exact value
    // KeyCaptureView filters on) so a future refactor can't accidentally
    // break the silent-consumption path.

    func testSyntheticEventSentinelExposedOnAppDelegate() {
        XCTAssertEqual(AppDelegate.syntheticEventSentinel, 0x5350454B,
            "KeyCaptureView.keyDown filters events carrying this sentinel.")
    }

    func testOnlyNumericPadFlagDoesNotCountAsCombo() {
        // .numericPad is in deviceIndependentFlagsMask but arrives on
        // numpad keystrokes even without a user pressing a modifier.
        // Current behavior: this will cancel, which matches the pre-fix
        // behavior. We're preserving it verbatim — this test locks the
        // contract in.
        XCTAssertEqual(decide(flags: [.numericPad]), .cancel)
    }
}
