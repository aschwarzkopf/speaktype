import AVFoundation
import XCTest
@testable import speaktype

/// Tests for the pure PCM buffer synthesis used by FeedbackSoundPlayer.
/// The AVAudioEngine playback path is not covered here — that needs a
/// real audio session and isn't meaningful in CI.
final class FeedbackSoundPlayerTests: XCTestCase {

    func testMakeBufferProducesCorrectFrameCount() {
        let buffer = FeedbackSoundPlayer.makeBuffer(
            frequencyHz: 880,
            durationMs: 100,
            amplitude: 0.15,
            sampleRate: 44_100
        )
        XCTAssertNotNil(buffer)
        // 100ms at 44.1kHz = 4410 frames.
        XCTAssertEqual(buffer?.frameLength, 4410)
    }

    func testMakeBufferAppliesDecayEnvelope() {
        let buffer = FeedbackSoundPlayer.makeBuffer(
            frequencyHz: 880,
            durationMs: 100,
            amplitude: 0.5,
            sampleRate: 44_100
        )
        guard let buffer, let samples = buffer.floatChannelData?[0] else {
            return XCTFail("Buffer generation failed")
        }

        // The envelope is exp(-5.0 / durationSec * t). Early samples should
        // be close to the configured amplitude; later samples should be
        // significantly attenuated. We probe the absolute value because
        // the sine wave alternates sign.
        let firstQuarterPeak = maxAbs(samples, in: 0..<Int(buffer.frameLength) / 4)
        let lastQuarterPeak = maxAbs(samples, in: (3 * Int(buffer.frameLength) / 4)..<Int(buffer.frameLength))

        XCTAssertGreaterThan(firstQuarterPeak, lastQuarterPeak,
            "Envelope should decay — early samples must peak higher than late samples.")
        XCTAssertGreaterThan(firstQuarterPeak, 0.3,
            "Early samples should reach most of the configured amplitude (0.5).")
    }

    func testMakeBufferRejectsInvalidInputs() {
        XCTAssertNil(FeedbackSoundPlayer.makeBuffer(
            frequencyHz: 0, durationMs: 100, amplitude: 0.15, sampleRate: 44_100))
        XCTAssertNil(FeedbackSoundPlayer.makeBuffer(
            frequencyHz: 880, durationMs: 0, amplitude: 0.15, sampleRate: 44_100))
        XCTAssertNil(FeedbackSoundPlayer.makeBuffer(
            frequencyHz: 880, durationMs: 100, amplitude: -0.1, sampleRate: 44_100))
    }

    func testStartAndStopFrequenciesFormDownwardInterval() {
        // UX contract: start pitch > stop pitch so the interval conveys
        // "begin listening" vs "committed."
        XCTAssertGreaterThan(
            FeedbackSoundPlayer.startFrequencyHz,
            FeedbackSoundPlayer.stopFrequencyHz)
    }

    // MARK: - Helpers

    private func maxAbs(_ samples: UnsafeMutablePointer<Float>, in range: Range<Int>) -> Float {
        var peak: Float = 0
        for i in range {
            peak = max(peak, abs(samples[i]))
        }
        return peak
    }
}
