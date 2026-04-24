import XCTest
@testable import speaktype

/// Tests for the MiniRecorderViewModel introduced to replace the prior
/// NotificationCenter round-trip + `.id(sessionID)` state-reset
/// machinery in MiniRecorderWindowController.
///
/// The VM owns all session-lifecycle @State that previously lived in
/// MiniRecorderView: isListening, isProcessing, isWarmingUp,
/// statusMessage, cancelCommit. The controller mutates VM state directly
/// instead of posting notifications; the view observes via @ObservedObject.
///
/// This is the "Option D" fix recommended by research — removes the
/// subscription-timing race that caused the "box appears, disappears, no
/// audio" bug without introducing SwiftUI view-identity churn.
@MainActor
final class MiniRecorderViewModelTests: XCTestCase {

    var vm: MiniRecorderViewModel!

    override func setUp() {
        super.setUp()
        vm = MiniRecorderViewModel()
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertFalse(vm.isListening)
        XCTAssertFalse(vm.isProcessing)
        XCTAssertFalse(vm.isWarmingUp)
        XCTAssertFalse(vm.cancelCommit)
        XCTAssertEqual(vm.pendingAction, .none)
        XCTAssertEqual(vm.statusMessage, MiniRecorderViewModel.defaultStatusMessage)
    }

    // MARK: - Session lifecycle

    func testStartSessionMintsFreshSessionID() {
        let before = vm.sessionID
        vm.startSession()
        XCTAssertNotEqual(vm.sessionID, before,
            "Each startSession must mint a new sessionID so observers can key on identity changes.")
    }

    func testStartSessionResetsStaleState() {
        // Simulate a prior session leaving dirty state behind — the bug
        // we're guarding against in the original Critical #3 audit note.
        vm.isListening = true
        vm.isProcessing = true
        vm.isWarmingUp = true
        vm.cancelCommit = true
        vm.statusMessage = "dirty"

        vm.startSession()

        XCTAssertFalse(vm.isListening)
        XCTAssertFalse(vm.isProcessing)
        XCTAssertFalse(vm.isWarmingUp)
        XCTAssertFalse(vm.cancelCommit)
        XCTAssertEqual(vm.statusMessage, MiniRecorderViewModel.defaultStatusMessage)
    }

    func testStartSessionSetsPendingActionStart() {
        vm.startSession()
        XCTAssertEqual(vm.pendingAction, .start,
            "The view observes pendingAction to know when to drive audioRecorder.startRecording().")
    }

    func testRequestStopSetsPendingActionStop() {
        vm.startSession()
        vm.requestStop()
        XCTAssertEqual(vm.pendingAction, .stop)
    }

    func testRequestCancelSetsPendingActionCancel() {
        vm.startSession()
        vm.requestCancel()
        XCTAssertEqual(vm.pendingAction, .cancel)
    }

    // MARK: - Commit / cancel callbacks

    func testCommitCallsOnCommitHandler() {
        var captured: String?
        vm.onCommit = { captured = $0 }
        vm.commit(text: "hello world")
        XCTAssertEqual(captured, "hello world")
    }

    func testCancelCallsOnCancelHandler() {
        var called = false
        vm.onCancel = { called = true }
        vm.cancel()
        XCTAssertTrue(called)
    }

    func testCommitResetsSessionFlags() {
        vm.isListening = true
        vm.isProcessing = true
        vm.commit(text: "anything")
        XCTAssertFalse(vm.isListening)
        XCTAssertFalse(vm.isProcessing)
    }

    func testCancelResetsSessionFlags() {
        vm.isListening = true
        vm.isProcessing = true
        vm.cancel()
        XCTAssertFalse(vm.isListening)
        XCTAssertFalse(vm.isProcessing)
    }

    // MARK: - Action consumption

    func testConsumeActionReturnsCurrentAndClears() {
        vm.startSession()
        let action = vm.consumeAction()
        XCTAssertEqual(action, .start)
        XCTAssertEqual(vm.pendingAction, .none,
            "consumeAction must clear pendingAction so repeated observers don't re-fire.")
    }

    func testConsumeActionWhenNoneReturnsNone() {
        XCTAssertEqual(vm.consumeAction(), .none)
    }

    // MARK: - Multiple sessions

    func testSecondStartSessionAfterCommitStartsClean() {
        vm.onCommit = { _ in }
        vm.startSession()
        vm.isListening = true
        vm.commit(text: "first")

        vm.startSession()
        XCTAssertFalse(vm.isListening)
        XCTAssertEqual(vm.pendingAction, .start)
    }
}
