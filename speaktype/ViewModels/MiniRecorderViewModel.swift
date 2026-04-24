import Foundation
import Combine

/// Drives the MiniRecorderView's session lifecycle. Owned by
/// MiniRecorderWindowController and observed by MiniRecorderView via
/// @ObservedObject. Replaces the prior NotificationCenter round-trip +
/// `.id(sessionID)` state-reset pattern, which had a subscription-timing
/// race (view's .onReceive wasn't live yet when the notification fired
/// synchronously after the rootView swap, so recording never started).
///
/// SwiftUI guarantees @Published observers are attached before any
/// mutation is observed, so this eliminates the race entirely.
@MainActor
final class MiniRecorderViewModel: ObservableObject {

    /// Default status string shown during transcription. Public for test
    /// comparison — the production code should not reference it directly.
    static let defaultStatusMessage = "Transcribing..."

    enum Action: Equatable {
        case none
        case start
        case stop
        case cancel
    }

    // MARK: - Session @State (moved off MiniRecorderView)

    @Published var isListening = false
    @Published var isProcessing = false
    @Published var isWarmingUp = false
    @Published var statusMessage = defaultStatusMessage
    @Published var cancelCommit = false

    // MARK: - Controller → view signaling

    /// Rotates on every startSession so the view can key lifecycle work
    /// off identity (via `.onChange(of: sessionID)`) without touching the
    /// view's own identity in SwiftUI's graph.
    @Published private(set) var sessionID = UUID()

    /// Most recent command from the controller. The view consumes this in
    /// `.onChange(of: pendingAction)`, dispatches the appropriate work,
    /// then calls `consumeAction()` to clear the slot.
    @Published private(set) var pendingAction: Action = .none

    // MARK: - Callbacks back to the controller

    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Controller API

    func startSession() {
        reset()
        sessionID = UUID()
        pendingAction = .start
    }

    func requestStop() {
        pendingAction = .stop
    }

    func requestCancel() {
        pendingAction = .cancel
    }

    // MARK: - View API

    func consumeAction() -> Action {
        let current = pendingAction
        pendingAction = .none
        return current
    }

    func commit(text: String) {
        onCommit?(text)
        reset()
    }

    func cancel() {
        onCancel?()
        reset()
    }

    // MARK: - Private

    private func reset() {
        isListening = false
        isProcessing = false
        isWarmingUp = false
        statusMessage = Self.defaultStatusMessage
        cancelCommit = false
    }
}
