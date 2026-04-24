import AVFoundation
import Foundation

/// Plays short synthesized feedback tones on recording start/stop.
/// Sounds are generated at runtime (no bundled audio assets) — a sine
/// wave shaped by an exponential decay envelope, then played through a
/// short-lived AVAudioEngine. ~100ms each, ~0.15 amplitude.
///
/// Disable via `UserDefaults`: set `feedbackSoundsEnabled = false`.
final class FeedbackSoundPlayer {
    static let shared = FeedbackSoundPlayer()

    /// Cached engines + player nodes per sound, lazily created on first
    /// play. Keeping them alive avoids the ~50ms engine-startup cost on
    /// every Fn press.
    private var startSound: PreparedSound?
    private var stopSound: PreparedSound?

    /// Tone parameters — tuned for a Wispr-flow-ish "soft blip" feel.
    /// `start` is slightly higher than `stop` to convey the direction of
    /// the action (rising = begin, falling = commit).
    static let startFrequencyHz: Float = 880     // A5
    static let startDurationMs: Int = 100
    static let stopFrequencyHz: Float = 660      // E5 — a perfect 4th below
    static let stopDurationMs: Int = 120
    static let amplitude: Float = 0.15

    private static let sampleRate: Double = 44_100

    private init() {}

    // MARK: - Public API

    func playStart() {
        guard Self.isEnabled else { return }
        if startSound == nil {
            startSound = Self.prepareSound(
                frequencyHz: Self.startFrequencyHz,
                durationMs: Self.startDurationMs
            )
        }
        startSound?.play()
    }

    func playStop() {
        guard Self.isEnabled else { return }
        if stopSound == nil {
            stopSound = Self.prepareSound(
                frequencyHz: Self.stopFrequencyHz,
                durationMs: Self.stopDurationMs
            )
        }
        stopSound?.play()
    }

    // MARK: - Settings

    static var isEnabled: Bool {
        // Default true — user can opt out via
        // `defaults write com.2048labs.speaktype feedbackSoundsEnabled -bool false`
        // (A UI toggle lives in Settings once wired up.)
        UserDefaults.standard.object(forKey: "feedbackSoundsEnabled") as? Bool ?? true
    }

    // MARK: - Sound synthesis

    /// Generate a short sine-wave PCM buffer with an exponential-decay
    /// envelope, attached to a ready-to-play AVAudioEngine.
    static func prepareSound(
        frequencyHz: Float,
        durationMs: Int,
        amplitude: Float = amplitude,
        sampleRate: Double = sampleRate
    ) -> PreparedSound? {
        let buffer = makeBuffer(
            frequencyHz: frequencyHz,
            durationMs: durationMs,
            amplitude: amplitude,
            sampleRate: sampleRate
        )
        guard let buffer else { return nil }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)

        do {
            try engine.start()
        } catch {
            print("FeedbackSoundPlayer: engine failed to start: \(error)")
            return nil
        }

        return PreparedSound(engine: engine, player: player, buffer: buffer)
    }

    /// Pure function — produces the PCM buffer for a tone. Public for
    /// testability; callers should normally use `playStart()` / `playStop()`.
    static func makeBuffer(
        frequencyHz: Float,
        durationMs: Int,
        amplitude: Float,
        sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        guard frequencyHz > 0, durationMs > 0, amplitude >= 0 else { return nil }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else { return nil }

        let frameCount = AVAudioFrameCount(Double(durationMs) * sampleRate / 1000.0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount

        guard let samples = buffer.floatChannelData?[0] else { return nil }

        // Exponential decay gives a natural "plucked" character. The
        // decay rate is tuned so the tone fades to near-silence by the
        // end of the buffer regardless of duration.
        let twoPiF = 2 * Float.pi * frequencyHz
        let decayRate = Float(5.0) / (Float(durationMs) / 1000.0)

        for i in 0..<Int(frameCount) {
            let t = Float(i) / Float(sampleRate)
            let envelope = exp(-decayRate * t)
            samples[i] = amplitude * envelope * sin(twoPiF * t)
        }

        return buffer
    }
}

/// Handle to a prepared, ready-to-play tone. Retained by
/// FeedbackSoundPlayer so the engine stays alive between plays.
final class PreparedSound {
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let buffer: AVAudioPCMBuffer

    init(engine: AVAudioEngine, player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) {
        self.engine = engine
        self.player = player
        self.buffer = buffer
    }

    func play() {
        // Each play schedules a fresh copy of the buffer — the player node
        // handles overlap cleanly if the user mashes the key.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }
}
