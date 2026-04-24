import AppKit
import XCTest
@testable import speaktype

/// Tests for MiniRecorderWindowController after the Option-D refactor:
/// the controller owns a MiniRecorderViewModel and drives it directly.
/// The old NotificationCenter path and the `.id(sessionID)` rebuild are
/// gone — session identity + state reset live on the VM.
@MainActor
final class MiniRecorderWindowControllerTests: XCTestCase {

    func testControllerInstantiates() {
        XCTAssertNotNil(MiniRecorderWindowController())
    }

    func testControllerExposesViewModel() {
        let controller = MiniRecorderWindowController()
        XCTAssertNotNil(controller.viewModel,
            "Controller must expose its VM so tests and the hosted view can observe state.")
    }

    // MARK: - Session lifecycle drives VM directly

    func testStartRecordingMintsFreshSessionIDOnViewModel() {
        let controller = MiniRecorderWindowController()
        let before = controller.viewModel.sessionID
        controller.startRecording()
        XCTAssertNotEqual(controller.viewModel.sessionID, before,
            "startRecording must rotate the VM's sessionID.")
    }

    func testStartRecordingSetsPendingActionStart() {
        let controller = MiniRecorderWindowController()
        controller.startRecording()
        XCTAssertEqual(controller.viewModel.pendingAction, .start,
            "Controller must request a start action on the VM so the hosted view reacts.")
    }

    func testStopRecordingRequestsStopOnViewModel() {
        let controller = MiniRecorderWindowController()
        controller.startRecording()
        controller.stopRecording()
        XCTAssertEqual(controller.viewModel.pendingAction, .stop)
    }

    func testCancelRecordingRequestsCancelOnViewModel() {
        let controller = MiniRecorderWindowController()
        controller.startRecording()
        controller.cancelRecording()
        XCTAssertEqual(controller.viewModel.pendingAction, .cancel)
    }

    func testEachStartRecordingMintsFreshSessionID() {
        let controller = MiniRecorderWindowController()
        let a = controller.viewModel.sessionID
        controller.startRecording()
        let b = controller.viewModel.sessionID
        controller.startRecording()
        let c = controller.viewModel.sessionID
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c,
            "Every startRecording call must mint a new session ID, not just the first.")
    }
}
