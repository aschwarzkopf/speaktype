import Foundation
import WhisperKit

@Observable
class WhisperService {
    // Shared singleton instance - use this everywhere
    static let shared = WhisperService()
    private static let placeholderPatterns = [
        #"\[(?:BLANK_AUDIO|SILENCE)\]"#,
        #"<\|nospeech\|>"#,
        #"\[\s*S\s*\]"#,
    ]
    private static let noiseLabelTerms = [
        "applause",
        "background noise",
        "blank audio",
        "breathing",
        "cough",
        "coughing",
        "exhale",
        "heartbeat",
        "indistinct",
        "inaudible",
        "inhale",
        "laughing",
        "laughter",
        "loud noise",
        "muffled speech",
        "music",
        "noise",
        "silence",
        "sigh",
        "sighs",
        "sniffing",
        "static",
        "unclear speech",
        "unintelligible",
        "wind",
        "wind blowing",
        "wind noise",
    ]
    private static let bracketedNoisePattern: String = {
        let escaped = noiseLabelTerms.map(NSRegularExpression.escapedPattern(for:)).joined(
            separator: "|")
        return #"[\[\(]\s*(?:"# + escaped + #")\s*[\]\)]"#
    }()

    /// Phrases Whisper hallucinates on silent or trailing-silence audio.
    /// Sourced from training-data biases — Whisper's corpus had heavy
    /// YouTube content with these closing phrases, plus phrases
    /// catalogued in openai/whisper issues #928, #1783 and the
    /// transformers PR #27658 hallucination list.
    ///
    /// Match strategy:
    ///   - Standalone (whole transcript ≈ phrase): return ""
    ///   - Trailing (phrase at the end + ≥5 substantive words before):
    ///     strip the trailing phrase and keep the prefix
    /// Mid-sentence appearances are preserved (user might literally
    /// say "thank you" as part of normal speech).
    ///
    /// Listed longest-first so regex alternation prefers specific
    /// matches over generic ones (e.g. "thank you for watching"
    /// before "thank you").
    private static let hallucinationPhrases: [String] = [
        "thank you so much for watching",
        "thank you for watching",
        "thanks for watching",
        "thank you for listening",
        "thanks for listening",
        "thank you very much",
        "i'll see you next time",
        "see you in the next video",
        "see you next time",
        "see you later",
        "thank you",
        "thanks",
        "please subscribe",
        "like and subscribe",
        "don't forget to subscribe",
        "subscribe to my channel",
        "bye bye",
        "bye-bye",
        "goodbye",
        "bye",
        "you",
    ]

    /// Minimum substantive words before a trailing hallucination for us
    /// to confidently strip it. Below this threshold we leave the text
    /// alone — the prefix isn't long enough to disambiguate "real
    /// transcript with a trailing 'thanks'" from "all-hallucination
    /// short utterance."
    private static let minPrefixWordsForTrailingStrip = 5

    var pipe: WhisperKit?
    var isInitialized = false
    var isTranscribing = false
    var isLoading = false
    var loadingStage: String = ""  // Descriptive stage for UI

    var currentModelVariant: String = ""  // No default - must be explicitly set

    /// Device RAM in GB (cached on init)
    static let deviceRAMGB: Int = {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }()

    enum TranscriptionError: Error, LocalizedError {
        case notInitialized
        case fileNotFound
        case alreadyLoading
        case loadingTimeout

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Model is not initialized"
            case .fileNotFound: return "Audio file not found"
            case .alreadyLoading: return "Model loading already in progress"
            case .loadingTimeout:
                return "Model loading timed out — your Mac may not have enough RAM for this model"
            }
        }
    }

    // Init is internal to allow testing, but prefer using .shared in production
    init() {}

    // Default initialization (loads default or saved model)
    func initialize() async throws {
        try await loadModel(variant: currentModelVariant)
    }

    // Dynamic model loading with optimized WhisperKitConfig
    func loadModel(variant: String) async throws {
        // Cheap pre-guard: if the caller already cancelled the task (e.g.
        // user rapidly switched models), short-circuit before flipping any
        // state or launching the expensive WhisperKit init.
        try Task.checkCancellation()

        // Already loaded this exact model
        if isInitialized && variant == currentModelVariant && pipe != nil {
            print("✅ Model \(variant) already loaded, skipping")
            return
        }

        // Prevent concurrent loading
        guard !isLoading else {
            print("⚠️ Model loading already in progress, skipping")
            throw TranscriptionError.alreadyLoading
        }

        let ramGB = Self.deviceRAMGB
        print("🔄 Initializing WhisperKit with model: \(variant)...")
        print("💻 Device RAM: \(ramGB) GB")

        if let model = AIModel.availableModels.first(where: { $0.variant == variant }),
            ramGB < model.minimumRAMGB
        {
            print(
                "⚠️ WARNING: Model \(variant) recommends \(model.minimumRAMGB)GB+ RAM, device has \(ramGB)GB. Loading may fail or be very slow."
            )
        }

        isLoading = true
        isInitialized = false
        loadingStage = "Preparing model..."
        // Guarantee isLoading resets on every exit path — success, throw,
        // or CancellationError — so a cancelled load never leaves the
        // service wedged as "already loading".
        defer {
            isLoading = false
            loadingStage = ""
        }

        // Release existing model to free memory
        if pipe != nil {
            print("🗑️ Releasing previous model from memory...")
            pipe = nil
        }

        let documentDirectory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        let modelFolderPath = documentDirectory.appendingPathComponent(
            "huggingface/models/argmaxinc/whisperkit-coreml/\(variant)"
        ).path

        // Use WhisperKitConfig with optimized settings
        let config = WhisperKitConfig(
            model: variant,
            modelFolder: modelFolderPath,
            computeOptions: ModelComputeOptions(),  // Uses GPU + Neural Engine
            verbose: false,
            logLevel: .error,
            prewarm: true,  // Built-in model specialization (replaces manual warmup)
            load: true,
            download: false  // Already downloaded via ModelDownloadService
        )

        loadingStage = "Loading AI model..."
        let loadStart = Date()

        let newPipe: WhisperKit
        do {
            newPipe = try await WhisperKit(config)
        } catch {
            print(
                "❌ Failed to initialize WhisperKit with \(variant): \(error.localizedDescription)")
            throw error
        }

        // Post-guard: WhisperKit's init is not interruptible, so if the
        // caller cancelled while we were awaiting, we now own a fully-
        // built pipe the caller no longer wants. Drop it and throw.
        do {
            try Task.checkCancellation()
        } catch {
            // Let ARC release newPipe.
            throw error
        }

        let loadDuration = Date().timeIntervalSince(loadStart)
        print("⏱️ Model loaded in \(String(format: "%.1f", loadDuration))s")

        pipe = newPipe
        currentModelVariant = variant
        isInitialized = true
        print("✅ WhisperKit initialized and prewarmed with \(variant)")
    }

    func transcribe(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            throw TranscriptionError.fileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }

        print("Starting transcription for: \(audioFile.lastPathComponent)")

        do {
            let options = decodingOptions(for: language)
            let results = try await pipe.transcribe(audioPath: audioFile.path, decodeOptions: options)
            let text = Self.normalizedTranscription(
                from: results.map { $0.text }.joined(separator: " "))

            print("Transcription complete: \(text.prefix(50))...")
            return text
        } catch {
            print("Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Transcribe a background audio chunk without affecting the global `isTranscribing` flag.
    /// Chunk files are automatically deleted after transcription.
    func transcribeChunk(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            // Chunk file may have been cleaned up already - return empty gracefully
            return ""
        }

        print("🔪 Chunk transcription started: \(audioFile.lastPathComponent)")

        let results = try await pipe.transcribe(
            audioPath: audioFile.path,
            decodeOptions: decodingOptions(for: language)
        )
        let text = Self.normalizedTranscription(from: results.map { $0.text }.joined(separator: " "))

        print("🔪 Chunk done: \(text.prefix(40))...")
        // Clean up temp chunk file after transcription
        try? FileManager.default.removeItem(at: audioFile)
        return text
    }

    private func decodingOptions(for language: String) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = (language == "auto") ? nil : language

        // VAD-based chunking. WhisperKit segments the audio by
        // detected voice activity and only feeds non-silent regions
        // to the model. This is the highest-leverage anti-hallucination
        // fix — Whisper never sees the trailing silence that triggers
        // "Thanks for watching" / "Thank you" because VAD trims it
        // before transcription. Recommended by faster-whisper docs,
        // whisper.cpp PR #2589, and openai/whisper issue #928.
        options.chunkingStrategy = .vad

        // Hallucination-suppression thresholds — slight tightening of
        // OpenAI defaults (0.6 / -1.0 / 2.4). Community guidance
        // (faster-whisper README, openai/whisper #928) is that defaults
        // are deliberate; aggressive tightening drops real quiet speech
        // too. We nudge noSpeech and logProb slightly tighter, leave
        // compressionRatio at default.
        options.noSpeechThreshold = 0.55
        options.logProbThreshold = -0.8
        options.compressionRatioThreshold = 2.4
        return options
    }

    static func normalizedTranscription(from rawText: String) -> String {
        var normalized = rawText

        for pattern in placeholderPatterns {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        normalized = normalized.replacingOccurrences(
            of: bracketedNoisePattern,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 1: standalone hallucination check. If the entire
        // transcript matches a known phrase (after stripping trailing
        // punctuation and whitespace), return empty — downstream
        // processRecording's `guard !text.isEmpty` then suppresses the
        // commit and treats it as "no speech detected."
        if isStandaloneHallucination(normalized) {
            return ""
        }

        // Step 2: trailing hallucination. If the very end of the
        // transcript is a known phrase AND the preceding content is
        // substantial (≥ 5 words), strip just the trailing phrase
        // while keeping the real content. Catches the common pattern
        // "<real speech>. Thank you." on recordings that fade into
        // silence.
        return strippingTrailingHallucination(normalized)
    }

    /// Compare-friendly form of a transcript: lowercase, strip leading
    /// and trailing whitespace + punctuation, collapse internal
    /// whitespace. Internal apostrophes are preserved so contractions
    /// like "don't" still match.
    private static func canonicalForm(_ text: String) -> String {
        let trimChars = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ".,!?;:…\"'`-—")
        )
        return text
            .lowercased()
            .trimmingCharacters(in: trimChars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func isStandaloneHallucination(_ text: String) -> Bool {
        let canonical = canonicalForm(text)
        if canonical.isEmpty { return true }
        return hallucinationPhrases.contains(canonical)
    }

    private static func strippingTrailingHallucination(_ text: String) -> String {
        // Try each phrase against the trailing portion, longest first
        // (already sorted that way in `hallucinationPhrases`).
        for phrase in hallucinationPhrases {
            // Pattern: optional terminator before the phrase, the phrase
            // itself, optional trailing punctuation+whitespace, end.
            let pattern = #"[.!?,]?\s+"# + NSRegularExpression.escapedPattern(for: phrase)
                + #"\s*[.!?,…]*\s*$"#
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }

            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: text, range: fullRange),
                match.range.length > 0
            else { continue }

            let prefix = nsText.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixWordCount = prefix
                .split(whereSeparator: { $0.isWhitespace })
                .count

            // Only strip if the prefix is substantial enough to
            // confidently classify the trailing phrase as hallucination
            // rather than the entire utterance.
            if prefixWordCount >= minPrefixWordsForTrailingStrip {
                return prefix
            }
            // First (longest) phrase matched but prefix was too short —
            // don't try shorter phrases on the same text (would over-cut).
            return text
        }
        return text
    }
}
