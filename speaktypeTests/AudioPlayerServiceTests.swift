import XCTest
@testable import speaktype

/// Tests for High #7: AudioPlayerService silently swallowed load failures
/// (`print(...)` only). Post-fix contract: `lastError` becomes a
/// @Published error that surfaces load failures to SwiftUI, and
/// `loadAudio` becomes `async throws` so callers can react.
@MainActor
final class AudioPlayerServiceTests: XCTestCase {

    func testLoadAudioFromMissingFileThrowsAndPublishesError() async {
        let service = AudioPlayerService.shared
        service.lastError = nil

        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).wav")

        do {
            try await service.loadAudio(from: bogusURL)
            XCTFail("loadAudio should have thrown for a missing file.")
        } catch {
            // Expected. Also verify the published error is set so UI can observe it.
            XCTAssertNotNil(service.lastError,
                "lastError must be published when loadAudio fails so the UI can react.")
        }
    }

    func testLastErrorStartsNil() {
        let service = AudioPlayerService.shared
        // Reset and assert the default state.
        service.lastError = nil
        XCTAssertNil(service.lastError)
    }

    func testSuccessfulLoadClearsPriorError() async throws {
        let service = AudioPlayerService.shared

        // Seed an error state, then load a valid file.
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus-\(UUID().uuidString).wav")
        _ = try? await service.loadAudio(from: bogus)
        XCTAssertNotNil(service.lastError)

        // Now generate a tiny valid WAV (44 bytes minimum header, 1 sample).
        let validURL = try makeTinyWAV()
        defer { try? FileManager.default.removeItem(at: validURL) }

        try await service.loadAudio(from: validURL)
        XCTAssertNil(service.lastError,
            "A successful load must clear lastError so stale UI errors don't linger.")
    }

    // MARK: - Helpers

    /// Build a minimal valid 16-bit mono 16kHz PCM WAV with one silent sample.
    private func makeTinyWAV() throws -> URL {
        var bytes = Data()
        let sampleRate: UInt32 = 16000
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign: UInt16 = channels * bitsPerSample / 8
        let sampleCount = 1
        let dataSize: UInt32 = UInt32(sampleCount) * UInt32(blockAlign)
        let fileSize: UInt32 = 36 + dataSize

        bytes.append("RIFF".data(using: .ascii)!)
        bytes.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        bytes.append("WAVE".data(using: .ascii)!)
        bytes.append("fmt ".data(using: .ascii)!)
        bytes.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })     // fmt chunk size
        bytes.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })      // PCM
        bytes.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        bytes.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        bytes.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        bytes.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        bytes.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        bytes.append("data".data(using: .ascii)!)
        bytes.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        bytes.append(Data(count: Int(dataSize)))                                    // silence

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-\(UUID().uuidString).wav")
        try bytes.write(to: url)
        return url
    }
}
