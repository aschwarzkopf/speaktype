import AVFoundation
import Combine
import CoreMedia
import SwiftUI

struct MiniRecorderView: View {
    @ObservedObject var viewModel: MiniRecorderViewModel
    @ObservedObject private var audioRecorder = AudioRecordingService.shared
    private var whisperService: WhisperService { WhisperService.shared }

    // View-only state (not session-lifecycle; kept local):
    @State private var showAccessibilityWarning = false

    @AppStorage("selectedModelVariant") private var selectedModel: String = ""
    @AppStorage("recordingMode") private var recordingMode: Int = 0
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = "auto"
    @AppStorage("recentTranscriptionLanguages") private var recentLanguagesString: String = ""
    @AppStorage("cleanupMode") private var cleanupModeRaw: String = CleanupMode.off.rawValue
    private var cleanupMode: CleanupMode {
        CleanupMode(rawValue: cleanupModeRaw) ?? .off
    }
    private let quickLanguageDefaults = ["en", "es", "fr", "de", "hi", "pt", "ja", "zh"]

    private var recentLanguageCodes: [String] {
        recentLanguagesString.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private var quickLanguageCodes: [String] {
        var orderedCodes: [String] = []
        let candidateCodes = [transcriptionLanguage] + recentLanguageCodes + quickLanguageDefaults

        for code in candidateCodes where code != "auto" {
            guard !orderedCodes.contains(code) else { continue }
            guard GeneralSettingsTab.whisperLanguages.contains(where: { $0.code == code }) else {
                continue
            }
            orderedCodes.append(code)
        }

        return Array(orderedCodes.prefix(6))
    }

    private func updateRecentLanguages(code: String) {
        guard code != "auto" else { return }
        var recents = recentLanguageCodes.filter { $0 != code }
        recents.insert(code, at: 0)
        recentLanguagesString = recents.prefix(5).joined(separator: ",")
    }

    private func setLanguage(_ code: String) {
        transcriptionLanguage = code
        updateRecentLanguages(code: code)
    }

    private var currentLanguageLabel: String {
        if transcriptionLanguage == "auto" { return "Auto" }
        return spokenLanguageDisplayName(for: transcriptionLanguage)
    }

    /// 2-character language label for the compact recorder chip.
    /// "auto" → a globe glyph; otherwise the uppercased 2-letter code.
    private var compactLanguageCode: String {
        if transcriptionLanguage == "auto" { return "🌐" }
        return transcriptionLanguage.prefix(2).uppercased()
    }

    /// Full human-readable name of the currently selected model, used
    /// in the brain-chip tooltip ("Active model: Medium — tap to switch").
    private var activeModelName: String {
        guard !selectedModel.isEmpty,
            let model = AIModel.availableModels.first(where: { $0.variant == selectedModel })
        else { return "none" }
        return model.name
    }

    private var spokenLanguageHelpText: String {
        if transcriptionLanguage == "auto" {
            return "Spoken language hint: Auto-detect. SpeakType will try to detect the language you are speaking."
        }

        return
            "Spoken language hint: \(spokenLanguageDisplayName(for: transcriptionLanguage)). If this does not match the language you actually speak, the result may be inaccurate or come back in the wrong language."
    }

    private var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    // Escape is captured via KeyEventHandlerView (NSView keyDown) now that
    // the hosting panel is a KeyableMiniRecorderPanel that can become key.

    // MARK: - State for Animation
    @State private var phase: CGFloat = 0

    // Calculate bar height based on audio level and position
    private func barHeight(for index: Int) -> CGFloat {
        // Defensive clamp — processAudioLevel normalizes to [0,1], but
        // any future bug upstream that produces a value outside that
        // range would push sqrt() to NaN/oversize and break the visual.
        let level = min(1.0, max(0.0, CGFloat(audioRecorder.audioLevel)))
        let baseHeight: CGFloat = 2
        let maxHeight: CGFloat = 16

        let waveOffset = sin(CGFloat(index) * 0.5 + phase) * 0.3
        let audioMultiplier = sqrt(level) * (0.8 + waveOffset)

        let height = baseHeight + (maxHeight - baseHeight) * audioMultiplier
        return max(baseHeight, min(height, maxHeight))
    }

    init(viewModel: MiniRecorderViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ZStack {
            backgroundView

            if viewModel.isWarmingUp || whisperService.isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .colorScheme(.dark)
                    Text("Warming up…")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .transition(.opacity)
            } else if viewModel.isProcessing {
                Text(viewModel.statusMessage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            } else {
                HStack(spacing: 4) {
                    stopButton

                    // Waveform — 11 bars at 3pt, stretched to fill the
                    // horizontal space left after button + model chip.
                    HStack(spacing: 2) {
                        ForEach(0..<11) { index in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.white.opacity(0.7))
                                .frame(width: 3, height: barHeight(for: index))
                                .animation(
                                    .easeInOut(duration: 0.15), value: audioRecorder.audioLevel)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)

                    // Compact model chip — brain SF Symbol. Tap opens the
                    // full model menu; language selection moved into the
                    // right-click context menu.
                    Menu {
                        modelSelectionMenu
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.28))
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 12, weight: .bold))
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.white)
                        }
                        .frame(width: 22, height: 22)
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .tint(.white)
                    .fixedSize()
                    .help("Active model: \(activeModelName) — tap to switch")
                }
                .padding(.horizontal, 4)
                .transition(.opacity)
            }
        }
        .frame(width: 140, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 1)
        .contextMenu {
            Menu("Language") {
                Button("Auto-detect") { setLanguage("auto") }
                if !quickLanguageCodes.isEmpty {
                    Divider()
                    ForEach(quickLanguageCodes, id: \.self) { code in
                        if let lang = GeneralSettingsTab.whisperLanguages.first(where: {
                            $0.code == code
                        }) {
                            Button(lang.name) { setLanguage(code) }
                        }
                    }
                }
                Divider()
                Menu("More languages") {
                    ForEach(GeneralSettingsTab.whisperLanguages, id: \.code) { lang in
                        Button(lang.name) { setLanguage(lang.code) }
                    }
                }
                if !recentLanguageCodes.isEmpty {
                    Divider()
                    Button("Clear recents") { recentLanguagesString = "" }
                }
            }
            Divider()
            Menu("Recording mode") {
                Button("Hold to record") { recordingMode = 0 }
                Button("Toggle to record") { recordingMode = 1 }
            }
        }
        .onChange(of: viewModel.pendingAction) { _, _ in
            // Drain the VM's action queue. SwiftUI guarantees this fires
            // after the @Published mutation is observed, so there is no
            // subscription race — the previous NotificationCenter path
            // could drop events if the view hadn't rendered yet.
            switch viewModel.consumeAction() {
            case .start:  startRecording()
            case .stop:   stopAndTranscribe()
            case .cancel: cancelRecording()
            case .none:   break
            }
        }
        .onAppear {
            initializedService()
        }
        .onChange(of: viewModel.isListening) {
            // Only animate when actually recording to save CPU
            if viewModel.isListening {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    phase = .pi * 4
                }
            } else {
                phase = 0
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Ensure focus if needed
        }
        .background(
            KeyEventHandlerView(onEscape: {
                handleEscape()
            })
        )
        .alert("Accessibility Permission Required", isPresented: $showAccessibilityWarning) {
            Button("Open Settings") {
                if let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Continue Anyway", role: .cancel) {}
        } message: {
            Text(
                "Accessibility is disabled. Transcribed text will be copied to clipboard but won't auto-paste into apps.\n\nEnable it in System Settings → Privacy & Security → Accessibility."
            )
        }
    }

    // MARK: - Subviews

    private var stopButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 1.0, green: 0.2, blue: 0.2))
                .frame(width: 20, height: 20)
                .shadow(color: Color.red.opacity(0.4), radius: 2, x: 0, y: 0)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.4))
                .frame(width: 6, height: 6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            handleHotkeyTrigger()
        }
    }

    private var backgroundView: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: 15)
                .clipShape(RoundedRectangle(cornerRadius: 15))

            RoundedRectangle(cornerRadius: 15)
                .fill(Color.black.opacity(0.85))

            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var modelSelectionMenu: some View {
        ForEach(AIModel.availableModels) { model in
            Button {
                let previousModel = selectedModel
                selectedModel = model.variant

                // Pre-load the new model immediately so the first transcription isn't slow
                if model.variant != previousModel {
                    Task {
                        await MainActor.run { viewModel.isWarmingUp = true }
                        do {
                            try await whisperService.loadModel(variant: model.variant)
                            debugLog("Model pre-loaded after switch: \(model.variant)")
                        } catch {
                            debugLog("Model pre-load failed: \(error.localizedDescription)")
                        }
                        await MainActor.run { viewModel.isWarmingUp = false }
                    }
                }
            } label: {
                if selectedModel == model.variant {
                    Label(model.name, systemImage: "checkmark")
                } else {
                    Text(model.name)
                }
            }
        }
    }

    // MARK: - Logic

    private func initializedService() {
        // Pre-warm the audio capture session for instant first recording
        audioRecorder.prewarmSession()

        guard !selectedModel.isEmpty else {
            debugLog("No model selected - skipping initialization")
            return
        }

        Task {
            debugLog("Initializing WhisperService with model: \(selectedModel)")
            do {
                try await whisperService.loadModel(variant: selectedModel)
                debugLog("Model preloaded successfully")
            } catch {
                debugLog("Model preload failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleHotkeyTrigger() {
        if viewModel.isListening {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func cancelRecording() {
        viewModel.cancelCommit = true

        guard viewModel.isListening || audioRecorder.isRecording else {
            viewModel.isProcessing = false
            viewModel.cancel()
            return
        }

        Task {
            _ = await audioRecorder.stopRecording(discardOutput: true)

            await MainActor.run {
                viewModel.isListening = false
                viewModel.isProcessing = false
                viewModel.statusMessage = "Transcribing..."
                viewModel.cancel()
            }
        }
    }

    private func startRecording() {
        guard !viewModel.isProcessing else {
            debugLog("Already processing, ignoring start request")
            return
        }

        guard !viewModel.isListening else {
            debugLog("Already listening, ignoring duplicate start request")
            return
        }

        // Check if accessibility is enabled - warn but don't block
        if !isAccessibilityEnabled {
            showAccessibilityWarning = true
        }

        // Check if model is selected BEFORE starting recording
        guard !selectedModel.isEmpty else {
            debugLog("No model selected - showing error")
            viewModel.isProcessing = true
            viewModel.statusMessage = "No model selected"

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                viewModel.isProcessing = false
                viewModel.cancel()
            }
            return
        }

        // Check if model is downloaded
        let progress = ModelDownloadService.shared.downloadProgress[selectedModel] ?? 0
        guard progress >= 1.0 else {
            debugLog("Model not downloaded - showing error")
            viewModel.isProcessing = true
            viewModel.statusMessage = "Model not downloaded"

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                viewModel.isProcessing = false
                viewModel.cancel()
            }
            return
        }

        viewModel.cancelCommit = false

        debugLog("Starting recording...")
        audioRecorder.startRecording()
        viewModel.isListening = true
    }

    private func stopAndTranscribe() {
        debugLog("stopAndTranscribe called")

        guard viewModel.isListening || audioRecorder.isRecording else {
            debugLog("Not listening, ignoring duplicate stop request")
            return
        }

        // Check if model is selected
        guard !selectedModel.isEmpty else {
            debugLog("No model selected - cannot transcribe")
            Task { @MainActor in
                viewModel.isListening = false
                viewModel.isProcessing = false
                viewModel.statusMessage = "No AI model selected. Go to Settings → AI Models to download one."

                // Show error for 3 seconds
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                viewModel.cancel()
            }
            return
        }

        Task {
            let url = await audioRecorder.stopRecording()
            debugLog("stopRecording returned: \(url?.absoluteString ?? "nil")")

            guard let url = url else {
                debugLog("No recording URL, cancelling")
                await MainActor.run {
                    viewModel.isListening = false
                    viewModel.cancel()
                }
                return
            }

            await MainActor.run {
                viewModel.isListening = false
                viewModel.isProcessing = true
                viewModel.statusMessage = "Transcribing..."
            }

            // Always use the final full-recording transcription for committed output.
            // Chunk stitching caused repeated phrases at boundaries across languages.
            await processRecording(url: url)
        }
    }

    private func handleEscape() {
        guard viewModel.isListening || viewModel.isProcessing || viewModel.isWarmingUp || whisperService.isLoading else { return }

        debugLog("Escape pressed - cancelling immediate commit")
        viewModel.cancelCommit = true

        if viewModel.isListening {
            Task {
                let url = await audioRecorder.stopRecording()

                await MainActor.run {
                    viewModel.isListening = false
                    viewModel.isProcessing = true
                    viewModel.statusMessage = "Stopping transcription..."
                }

                if let url = url {
                    // Let it process in the background and save to history, but don't commit to UI
                    await processRecording(url: url)
                } else {
                    await MainActor.run {
                        viewModel.cancel()
                    }
                }
            }
        } else {
            // Already processing, just show stopping and quickly dismiss
            viewModel.statusMessage = "Stopping transcription..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                viewModel.cancel()
            }
        }
    }

    private func debugLog(_ message: String) {
        // Only write to disk in DEBUG builds. Release builds fall back to
        // the unified logging system (os_log) so we don't leak diagnostic
        // text to a world-readable file in shipped binaries.
        #if DEBUG
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let logDir = appSupport.appendingPathComponent("SpeakType/Logs")
        try? FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("debug.log")
        let entry = "[\(Date())] \(message)\n"
        guard let data = entry.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFile.path),
           let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logFile)
        }
        #else
        print("[SpeakType] \(message)")
        #endif
    }

    private func processRecording(url: URL) async {
        debugLog("processRecording started with url: \(url.lastPathComponent)")
        do {
            // Ensure model is loaded before transcribing
            if !whisperService.isInitialized || whisperService.currentModelVariant != selectedModel
            {
                debugLog("Loading model: \(selectedModel)")
                await MainActor.run { viewModel.statusMessage = "Warming up model — first use is slower..." }
                do {
                    try await whisperService.loadModel(variant: selectedModel)
                    debugLog("Model loaded successfully")
                } catch {
                    debugLog("Model load failed: \(error.localizedDescription)")
                    await MainActor.run {
                        viewModel.statusMessage = "Model load failed"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            viewModel.isProcessing = false
                            viewModel.cancel()
                        }
                    }
                    return
                }
            }

            debugLog("Starting transcription...")
            // If user has already cancelled (pressed Escape), skip transcription UI updates
            // but still run the transcription in the background to save to history
            if !viewModel.cancelCommit {
                await MainActor.run { viewModel.statusMessage = "Transcribing..." }
            }
            let rawText = try await whisperService.transcribe(audioFile: url, language: transcriptionLanguage)
            debugLog("Transcription result: \(rawText.prefix(50))...")

            // Optional cleanup pass — Phase 1 routes all modes to the
            // pass-through IdentityPolisher, so this is a no-op until
            // Phase 2 / Phase 3 plug in the real implementations. The
            // try?-fallback guarantees cleanup failures never block the
            // user's paste flow: worst case, the raw transcript is used.
            let polisher = PolisherFactory.make(mode: cleanupMode)
            let text = (try? await polisher.polish(rawText)) ?? rawText

            guard !text.isEmpty else {
                debugLog("Empty text, cancelling")
                await MainActor.run {
                    viewModel.statusMessage = "No speech detected"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        viewModel.isProcessing = false
                        viewModel.cancel()
                    }
                }
                return
            }

            let duration = await getAudioDuration(url: url)
            let modelName =
                AIModel.availableModels.first(where: { $0.variant == selectedModel })?.name
                ?? selectedModel
            HistoryService.shared.addItem(
                transcript: text,
                duration: duration,
                audioFileURL: url,
                modelUsed: modelName,
                transcriptionTime: nil
            )

            debugLog("Calling onCommit...")
            await MainActor.run {
                if !viewModel.cancelCommit {
                    viewModel.commit(text: text)
                }
                viewModel.isProcessing = false

                // If we cancelled by dismissing early, the window might already be closed,
                // but if we waited for it (e.g. short transcription), close it now.
                if viewModel.cancelCommit {
                    viewModel.cancel()
                }
            }
            debugLog("onCommit called successfully")
        } catch {
            debugLog("Error: \(error.localizedDescription)")
            await MainActor.run {
                viewModel.statusMessage = "Transcription failed"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    viewModel.isProcessing = false
                    viewModel.cancel()
                }
            }
        }
    }

    private func getAudioDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return 0
        }
    }

    private func spokenLanguageDisplayName(for code: String) -> String {
        if code == "auto" { return "Auto-detect" }
        return GeneralSettingsTab.whisperLanguages.first(where: { $0.code == code })?.name ?? code
    }
}

// MARK: - Helper Shapes & Views

struct HorizontalWave: Shape {
    var phase: CGFloat
    var amplitude: CGFloat
    var frequency: CGFloat

    // Allow animation of phase, amplitude, AND frequency
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(phase, AnimatablePair(amplitude, frequency)) }
        set {
            phase = newValue.first
            amplitude = newValue.second.first
            frequency = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let midHeight = height / 2

        // Start at left middle
        path.move(to: CGPoint(x: 0, y: midHeight))

        for x in stride(from: 0, through: width, by: 1) {
            let relativeX = x / width

            // Sine wave formula: y = A * sin(kx - wt)
            // k = 2pi * frequency (cycles across width)
            // wt = phase
            let sine = sin((relativeX * .pi * 2 * frequency) - phase)

            let y = midHeight + sine * amplitude

            path.addLine(to: CGPoint(x: x, y: y))
        }

        return path
    }
}

struct ChevronShape: Shape {
    let pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()

        if pointsUp {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        return path
    }
}

struct DoubleChevronIcon: View {
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            ChevronShape(pointsUp: true)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 7, height: 4)

            ChevronShape(pointsUp: false)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 7, height: 4)
        }
        .frame(width: 8, height: 10)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active

        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.masksToBounds = true

        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
    }
}

// MARK: - Key Event Handler

struct KeyEventHandlerView: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? KeyCaptureView {
            view.onEscape = onEscape
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    class KeyCaptureView: NSView {
        var onEscape: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            // Silently consume our own synthetic events. `suppressEmojiPicker`
            // in AppDelegate posts an F19 keyDown with the 'SPEK' sentinel
            // stamped on its CGEvent; without this guard it falls through
            // `super.keyDown` and produces NSBeep since nothing in the
            // responder chain handles F19. (More frequent on rapid Fn
            // presses because first-responder setup wins the race.)
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                == AppDelegate.syntheticEventSentinel {
                return
            }
            if event.keyCode == 53 {  // Escape key
                onEscape?()
                return
            }
            super.keyDown(with: event)
        }
    }
}
