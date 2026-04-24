import Foundation
import AVFoundation
import Combine

enum AudioPlayerError: LocalizedError, Identifiable {
    case loadFailed(underlying: Error)

    var id: String { localizedDescription }

    var errorDescription: String? {
        switch self {
        case .loadFailed(let err):
            return "Couldn't load audio file: \(err.localizedDescription)"
        }
    }
}

/// Service for playing back audio recordings
@MainActor
class AudioPlayerService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerService()

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentAudioURL: URL?
    /// Last error produced by loadAudio. Views can observe this via
    /// `.alert(item:)`; setting it back to nil dismisses the alert.
    @Published var lastError: AudioPlayerError?

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?

    private override init() {
        super.init()
    }

    /// Load audio file and prepare for playback.
    /// Throws AudioPlayerError on failure and publishes it via `lastError`
    /// so passive SwiftUI bindings can react.
    func loadAudio(from url: URL) async throws {
        stop()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()

            audioPlayer = player
            currentAudioURL = url
            duration = player.duration
            currentTime = 0
            lastError = nil
        } catch {
            let wrapped = AudioPlayerError.loadFailed(underlying: error)
            lastError = wrapped
            audioPlayer = nil
            currentAudioURL = nil
            duration = 0
            throw wrapped
        }
    }
    
    /// Start or resume playback
    func play() {
        guard let player = audioPlayer else { return }
        player.play()
        isPlaying = true
        startTimer()
    }
    
    /// Pause playback
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
    }
    
    /// Stop playback and reset to beginning
    func stop() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
    }
    
    /// Seek to specific time in the audio
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = min(max(0, time), duration)
        currentTime = player.currentTime
    }
    
    /// Reset player completely
    func reset() {
        stop()
        audioPlayer = nil
        currentAudioURL = nil
        duration = 0
        currentTime = 0
    }
    
    // MARK: - Private Methods
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.currentTime = player.currentTime
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimer()
        currentTime = 0
        player.currentTime = 0
    }
}
