import ApplicationServices
import Cocoa

/// Abstracts the AX query for whether the currently-focused UI element
/// accepts text input. Production implementation talks to the macOS
/// Accessibility API; tests inject a stub that returns a canned value.
protocol FocusedElementInspector {
    func acceptsText() -> Bool
}

/// Production implementation — queries the system-wide focused element
/// and applies a layered-signal check to classify it as text-accepting
/// or not.
///
/// Role-only detection false-negatives on Electron contenteditable
/// surfaces (Slack, Discord, VS Code Copilot chat), custom-renderer
/// terminals (Warp, Ghostty), and some Flutter / Tauri apps. We
/// combine three signals:
///
///   1. `kAXRoleAttribute` ∈ known editable role set
///   2. `AXInsertionPointLineNumber` readable (caret exists = real text)
///   3. `kAXValueAttribute` marked as settable
///
/// All AX calls are timeout-guarded at 100 ms via
/// `AXUIElementSetMessagingTimeout` so a frozen target app cannot hang
/// the paste pipeline.
struct AXFocusedElementInspector: FocusedElementInspector {

    /// AXRoles we treat as confirmed text-accepting. Any of these on the
    /// focused element → accept paste immediately.
    static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",      // used by Safari URL bar, App Store, Mail
        "AXSecureTextField",  // password fields
    ]

    /// Cap on each AX IPC call. Frozen target apps are real in the wild
    /// (backgrounded Electron apps, crashed third-party helpers); 100ms
    /// is well above the measured 0.2–2ms happy-path latency yet
    /// short enough that the paste flow stays responsive.
    static let messagingTimeout: Float = 0.1

    func acceptsText() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)

        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            ) == .success,
            let focused = focusedRef
        else { return false }

        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

        // Signal 1 — role is in the known-editable set.
        if let role = Self.copyStringAttribute(element, kAXRoleAttribute as CFString),
            Self.editableRoles.contains(role)
        {
            return true
        }

        // Signal 2 — element reports an insertion point, which means a
        // caret exists and a user could type. Stronger signal than role
        // for custom-rendered text surfaces.
        var insertionRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            "AXInsertionPointLineNumber" as CFString,
            &insertionRef
        ) == .success, insertionRef != nil {
            return true
        }

        // Signal 3 — kAXValueAttribute is settable. Fallback for
        // non-standard roles that still expose a mutable value.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success, settable.boolValue {
            return true
        }

        return false
    }

    private static func copyStringAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, name, &value) == .success
        else { return nil }
        return value as? String
    }
}

/// High-level "should we post Cmd+V right now?" decision. Combines the
/// AX inspector result with a small bundle-ID allowlist of apps whose
/// AX reporting is known-broken but whose paste reliably works.
enum PasteEligibility {

    /// Bundle IDs where the AX preflight false-negatives (usually
    /// custom-rendered text surfaces) but Cmd+V still pastes correctly.
    /// Additions require empirical verification — keep small and
    /// explicit. Research-flagged candidates: Warp, Ghostty, older
    /// JetBrains; start conservative with just Warp.
    static let forceAllowedBundleIDs: Set<String> = [
        "dev.warp.Warp-Stable"
    ]

    /// Returns true if the caller should proceed with auto-paste.
    ///
    /// - Parameters:
    ///   - inspector: AX surface query. Defaults to the production AX
    ///     implementation; tests inject a stub.
    ///   - frontmostBundleID: Current frontmost app's bundle ID for
    ///     allowlist lookup. Defaults to whatever NSWorkspace reports.
    static func canAutoPaste(
        inspector: FocusedElementInspector = AXFocusedElementInspector(),
        frontmostBundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    ) -> Bool {
        if let bundleID = frontmostBundleID,
            forceAllowedBundleIDs.contains(bundleID)
        {
            return true
        }
        return inspector.acceptsText()
    }
}
