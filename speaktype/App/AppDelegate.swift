import Combine
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var miniRecorderController: MiniRecorderWindowController?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var hotkeyEventTap: CFMachPort?
    private var hotkeyEventTapSource: CFRunLoopSource?
    var isHotkeyPressed = false
    private var cancellables = Set<AnyCancellable>()
    private var lastHandledHotkeyTimestamp: TimeInterval = 0
    private var lastHandledHotkeyPressedState = false
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    /// Sentinel stamped into every synthetic CGEvent we post ourselves
    /// (currently just the F19 pair from `suppressEmojiPicker`). macOS 26
    /// composes live modifier state onto `.hidSystemState`-sourced events,
    /// so a synthesized F19 posted while Fn is held comes back carrying
    /// `.function` and would otherwise trip `handleModifierComboEvent`'s
    /// combo-cancel guard. Filtering on this sentinel is robust to user
    /// remapping and independent of which keyCode we synthesize.
    static let syntheticEventSentinel: Int64 = 0x5350454B  // 'SPEK'

    // MARK: - Pure hotkey decision (testable, no AppKit dependency)

    enum HotkeyDecision: Equatable {
        case ignore
        case cancel
    }

    static func decideComboEvent(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        hotkeyCode: UInt16,
        isHotkeyPressed: Bool,
        recordingMode: Int,
        isSynthetic: Bool
    ) -> HotkeyDecision {
        if isSynthetic { return .ignore }
        guard isHotkeyPressed else { return .ignore }
        guard recordingMode == 0 else { return .ignore }
        guard !flags.intersection(.deviceIndependentFlagsMask).isEmpty else { return .ignore }
        guard keyCode != hotkeyCode else { return .ignore }
        return .cancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        miniRecorderController = MiniRecorderWindowController()

        // Setup dynamic hotkey monitoring based on user selection
        setupHotkeyMonitoring()

        // Bring up Sparkle. It reads SUFeedURL + SUPublicEDKey from
        // Info.plist and starts scheduling background checks on its
        // own — Sparkle's standard UI handles the "update available"
        // dialog and install-on-quit prompt. No custom update
        // notification machinery needed.
        SparkleUpdater.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Emoji Picker Suppression

    private func suppressEmojiPicker() {
        // Post a harmless F19 keydown/keyup to break the Globe key's double-tap
        // or press-and-release detection in the system emoji picker.
        //
        // Two protections against the macOS 26 modifier-composition behavior:
        // 1. `.privateState` source — does not merge live modifier state at
        //    post time, so the synthesized event doesn't inherit `.function`
        //    from a physically-held Fn.
        // 2. `eventSourceUserData` sentinel — tags the event so our own
        //    handlers can unambiguously identify and ignore it, even if the
        //    user has remapped F19 or a third-party remapper is in the loop.
        let dummyKeyCode: CGKeyCode = 0x50  // F19 (80)
        guard let source = CGEventSource(stateID: .privateState) else { return }

        for keyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: dummyKeyCode, keyDown: keyDown
            ) else { continue }
            event.flags = []  // explicit: no modifier composition
            event.setIntegerValueField(
                .eventSourceUserData, value: Self.syntheticEventSentinel
            )
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Hotkey Monitoring

    private func setupHotkeyMonitoring() {
        setupSuppressingHotkeyEventTap()

        // Add global monitor for hotkey events
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleHotkeyEvent(event)
        }

        // Add local monitor for hotkey events (same logic)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleHotkeyEvent(event)
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleModifierComboEvent(event)
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleModifierComboEvent(event)
            return event
        }
    }

    private func setupSuppressingHotkeyEventTap() {
        guard hotkeyEventTap == nil else { return }

        // Also watch keyDown so we can drop our own synthetic F19 events
        // (from suppressEmojiPicker) at the tap level — before they can
        // become NSEvents and trigger NSBeep or false-positive combo-
        // cancels in handleModifierComboEvent. The CGEvent user-data
        // field is reliable here; the NSEvent.cgEvent wrapper is not.
        let eventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            return appDelegate.handleHotkeyEventTap(type: type, event: event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            print("Failed to create suppressing hotkey event tap")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        hotkeyEventTap = eventTap
        hotkeyEventTapSource = runLoopSource
    }

    private func handleHotkeyEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let hotkeyEventTap {
                CGEvent.tapEnable(tap: hotkeyEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Drop our own synthetic events from the stream entirely. This
        // prevents NSBeep (from unhandled F19 in the responder chain)
        // AND prevents false positives in handleModifierComboEvent
        // (which can't reliably read the sentinel from NSEvent.cgEvent).
        // Returning nil deletes the event per CGEventTapCallBack docs.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventSentinel {
            return nil
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let currentHotkey = getSelectedHotkey()
        guard currentHotkey == .fn else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == currentHotkey.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isPressed = event.flags.contains(.maskSecondaryFn)
        DispatchQueue.main.async { [weak self] in
            self?.handleHotkeyStateChange(isPressed: isPressed)
        }

        // Suppress the Fn flagsChanged event so terminal apps do not receive raw CSI sequences.
        return nil
    }

    private func handleHotkeyEvent(_ event: NSEvent) {
        let currentHotkey = getSelectedHotkey()
        guard event.keyCode == currentHotkey.keyCode else { return }

        let isPressed = event.modifierFlags.contains(currentHotkey.modifierFlag)
        handleHotkeyStateChange(isPressed: isPressed)
    }

    private func handleHotkeyStateChange(isPressed: Bool) {
        guard !isDuplicateHotkeyEvent(isPressed: isPressed) else { return }

        let currentHotkey = getSelectedHotkey()
        if isPressed && !isHotkeyPressed {
            isHotkeyPressed = true

            if currentHotkey == .fn {
                suppressEmojiPicker()
            }

            let recordingMode = UserDefaults.standard.integer(forKey: "recordingMode")
            if recordingMode == 1 {
                if AudioRecordingService.shared.isRecording {
                    miniRecorderController?.stopRecording()
                } else {
                    miniRecorderController?.startRecording()
                }
            } else {
                miniRecorderController?.startRecording()
            }
        } else if !isPressed && isHotkeyPressed {
            isHotkeyPressed = false

            let recordingMode = UserDefaults.standard.integer(forKey: "recordingMode")
            if recordingMode == 0 {
                miniRecorderController?.stopRecording()
            }
        }
    }

    private func handleModifierComboEvent(_ event: NSEvent) {
        let isSynthetic = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            == Self.syntheticEventSentinel
        let decision = Self.decideComboEvent(
            keyCode: event.keyCode,
            flags: event.modifierFlags,
            hotkeyCode: getSelectedHotkey().keyCode,
            isHotkeyPressed: isHotkeyPressed,
            recordingMode: UserDefaults.standard.integer(forKey: "recordingMode"),
            isSynthetic: isSynthetic
        )
        switch decision {
        case .cancel:
            isHotkeyPressed = false
            miniRecorderController?.cancelRecording()
        case .ignore:
            return
        }
    }

    private func isDuplicateHotkeyEvent(isPressed: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let isDuplicate =
            abs(now - lastHandledHotkeyTimestamp) < 0.05
            && lastHandledHotkeyPressedState == isPressed

        lastHandledHotkeyTimestamp = now
        lastHandledHotkeyPressedState = isPressed
        return isDuplicate
    }

    private func getSelectedHotkey() -> HotkeyOption {
        // Migration: Check if old useFnKey setting exists
        if UserDefaults.standard.object(forKey: "useFnKey") != nil {
            let useFnKey = UserDefaults.standard.bool(forKey: "useFnKey")
            if useFnKey {
                UserDefaults.standard.set(HotkeyOption.fn.rawValue, forKey: "selectedHotkey")
                UserDefaults.standard.removeObject(forKey: "useFnKey")
                return .fn
            }
        }

        if let rawValue = UserDefaults.standard.string(forKey: "selectedHotkey"),
            let option = HotkeyOption(rawValue: rawValue)
        {
            return option
        }

        return .fn
    }

}
