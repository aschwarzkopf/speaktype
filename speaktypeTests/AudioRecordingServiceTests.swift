import XCTest
@testable import speaktype

final class AudioRecordingServiceTests: XCTestCase {
    
    var service: AudioRecordingService!
    
    override func setUpWithError() throws {
        service = AudioRecordingService()
    }

    override func tearDownWithError() throws {
        service = nil
    }

    func testInitialization() {
        XCTAssertNotNil(service)
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.audioLevel, 0.0)
    }
    
    func testStopRecordingWhenNotRecording() async {
        let url = await service.stopRecording()
        XCTAssertNil(url, "Should return nil url when not recording")
    }

    // MARK: - Critical #1: Writer race safety
    // These tests verify the status-enum gating introduced to replace the
    // insufficient `isStopping: Bool` flag. They must not crash under
    // rapid/concurrent stop calls (RosyWriter-style safety contract).

    func testDoubleStopRecordingIsSafe() async {
        // Two sequential stops must both return nil (nothing to finalize)
        // and must not crash due to double finishWriting / nil writer access.
        let first = await service.stopRecording()
        let second = await service.stopRecording()
        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    func testConcurrentStopRecordingIsSafe() async {
        // Fire many concurrent stops. Under the old code this could crash
        // if one task nilled the writer while another was calling finishWriting.
        // With the status-enum gate, all extras must be no-ops returning nil.
        await withTaskGroup(of: URL?.self) { group in
            for _ in 0..<8 {
                group.addTask { await self.service.stopRecording() }
            }
            for await _ in group { /* drain */ }
        }
        XCTAssertFalse(service.isRecording,
            "isRecording must be false after all concurrent stops complete.")
    }

    func testConcurrentStopRecordingWithDiscardIsSafe() async {
        // Same race surface, exercising the discardOutput=true path which
        // mutates shouldDiscardCurrentRecordingOutput from multiple callers.
        await withTaskGroup(of: URL?.self) { group in
            for i in 0..<6 {
                let discard = i.isMultiple(of: 2)
                group.addTask { await self.service.stopRecording(discardOutput: discard) }
            }
            for await _ in group { /* drain */ }
        }
        XCTAssertFalse(service.isRecording)
    }

    func testIsRecordingFalseAfterStop() async {
        _ = await service.stopRecording()
        XCTAssertFalse(service.isRecording,
            "isRecording must flip to false synchronously on the main actor before finalize.")
    }

    func testStopRecordingResetsAudioLevel() async {
        // Simulate a non-zero level left over from a previous buffer.
        service.audioLevel = 0.5
        service.audioFrequency = 0.3
        _ = await service.stopRecording()
        // Level reset is dispatched async to main; wait a tick.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.audioLevel, 0.0,
            "audioLevel must reset to 0 after stop so stale values don't feed the next session.")
        XCTAssertEqual(service.audioFrequency, 0.0)
    }
}
