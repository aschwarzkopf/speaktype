import Foundation
import Combine
import SwiftUI // For IndexSet operations if needed, though Foundation usually covers it, but error says missing import.

struct HistoryStatsEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let wordCount: Int
    let duration: TimeInterval
}

struct HistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let transcript: String
    let duration: TimeInterval
    let audioFileURL: URL?
    let modelUsed: String?
    let transcriptionTime: TimeInterval?
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.id == rhs.id
    }
}

class HistoryService: ObservableObject {
    static let shared = HistoryService()

    @Published var items: [HistoryItem] = []
    @Published private(set) var statsEntries: [HistoryStatsEntry] = []

    /// Legacy UserDefaults keys, kept for one-time migration on first
    /// launch after upgrading from the all-UserDefaults storage layout.
    private let saveKey = "history_items"
    private let statsSaveKey = "history_stats_entries"

    /// File-backed store for transcription history. Replaces the
    /// previous UserDefaults blob (which lost data on SIGKILL because
    /// UserDefaults buffers writes). NDJSON file in Application Support.
    private let store: HistoryStore

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("SpeakType")
        self.store = HistoryStore(directory: appSupport)

        // Stats remain in UserDefaults for now — they're small and
        // less critical than the transcripts themselves. The
        // synchronize() call in saveStats() forces immediate flush,
        // matching the durability expectation set by the file store.
        loadStats()

        // Load order: migrate from UserDefaults if needed, then read
        // the file. Both happen in a Task so init returns promptly;
        // SwiftUI views observing `items` will update when load
        // completes.
        Task { @MainActor in
            await migrateLegacyHistoryIfNeeded()
            await loadHistoryFromFile()
        }
    }
    
    func addItem(transcript: String, duration: TimeInterval, audioFileURL: URL? = nil, modelUsed: String? = nil, transcriptionTime: TimeInterval? = nil) {
        let normalizedTranscript = WhisperService.normalizedTranscription(from: transcript)
        guard !normalizedTranscript.isEmpty else { return }

        let timestamp = Date()
        let wordCount = normalizedTranscript.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count

        let newItem = HistoryItem(
            id: UUID(),
            date: timestamp,
            transcript: normalizedTranscript,
            duration: duration,
            audioFileURL: audioFileURL,
            modelUsed: modelUsed,
            transcriptionTime: transcriptionTime
        )
        let statsEntry = HistoryStatsEntry(
            id: newItem.id,
            date: timestamp,
            wordCount: wordCount,
            duration: duration
        )
        items.insert(newItem, at: 0) // Newest first
        statsEntries.insert(statsEntry, at: 0)
        saveHistory()
        saveStats()
        // O(1) append to the NDJSON file — no full rewrite.
        Task { try? await store.append(newItem) }
    }
    
    func deleteItem(at offsets: IndexSet, deleteAudioFile: Bool = true) {
        // Filter offsets to those still in range — SwiftUI can hand us
        // stale indices during rapid delete operations, and
        // `remove(atOffsets:)` crashes on out-of-bounds entries.
        let validOffsets = IndexSet(offsets.filter { items.indices.contains($0) })
        guard !validOffsets.isEmpty else { return }

        let itemsToDelete = validOffsets.map { items[$0] }
        items.remove(atOffsets: validOffsets)
        if deleteAudioFile {
            itemsToDelete.forEach(removeAudioFileIfNeeded(for:))
        }
        saveHistory()
        rewriteFileSnapshot()
    }

    func deleteItem(id: UUID, deleteAudioFile: Bool = true) {
        let itemToDelete = items.first { $0.id == id }
        items.removeAll { $0.id == id }
        if deleteAudioFile, let itemToDelete {
            removeAudioFileIfNeeded(for: itemToDelete)
        }
        saveHistory()
        rewriteFileSnapshot()
    }

    func clearAll() {
        items.removeAll()
        saveHistory()
        rewriteFileSnapshot()
    }

    /// Rewrite the file from the current `items` array. Used after
    /// edits/deletes; appends use the cheaper append path.
    /// File order is chronological (oldest first); items array is
    /// newest first, so we reverse on the way out.
    private func rewriteFileSnapshot() {
        let snapshot = Array(items.reversed())
        Task { try? await store.rewrite(snapshot) }
    }

    func totalWordCount() -> Int {
        statsEntries.reduce(0) { $0 + $1.wordCount }
    }
    
    func transcriptionCount(since startDate: Date? = nil) -> Int {
        filteredStatsEntries(since: startDate).count
    }
    
    func totalDuration(since startDate: Date? = nil) -> TimeInterval {
        filteredStatsEntries(since: startDate).reduce(0) { $0 + $1.duration }
    }
    
    func wordCount(on day: Date, calendar: Calendar = .current) -> Int {
        let startOfDay = calendar.startOfDay(for: day)
        return statsEntries
            .filter { calendar.isDate($0.date, inSameDayAs: startOfDay) }
            .reduce(0) { $0 + $1.wordCount }
    }
    
    func statsEntries(since startDate: Date) -> [HistoryStatsEntry] {
        filteredStatsEntries(since: startDate)
    }
    
    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
            // Force an immediate flush to disk. UserDefaults normally
            // buffers writes and only persists on app termination or
            // periodic flush — but `make build` / Xcode rebuild kills
            // the running app via SIGKILL, which skips the graceful
            // shutdown that would flush the buffer. synchronize() is
            // formally deprecated for "normal use" but it's exactly
            // the right tool here. Without it, a transcription saved
            // moments before rebuild is lost.
            UserDefaults.standard.synchronize()
        }
    }

    private func saveStats() {
        if let encoded = try? JSONEncoder().encode(statsEntries) {
            UserDefaults.standard.set(encoded, forKey: statsSaveKey)
            UserDefaults.standard.synchronize()
        }
    }
    
    /// Migrate history from the legacy UserDefaults blob to the file
    /// store. One-time, idempotent: only runs when the file doesn't
    /// exist yet AND there's data in the old key. Leaves the legacy
    /// UserDefaults entry in place as a backup until manually cleared.
    private func migrateLegacyHistoryIfNeeded() async {
        let fileURL = await store.fileURL
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = UserDefaults.standard.data(forKey: saveKey),
            let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data),
            !decoded.isEmpty
        else { return }

        // Legacy data was stored newest-first (insert at 0). The file
        // expects chronological order, so reverse before writing.
        let chronological = Array(decoded.reversed())
        do {
            try await store.rewrite(chronological)
            print("ℹ️ Migrated \(chronological.count) history items from UserDefaults → file store")
        } catch {
            print("⚠️ History migration failed: \(error)")
        }
    }

    /// Load all items from the NDJSON file into the published `items`
    /// array, applying transcript-normalization (catches old entries
    /// that pre-date the hallucination filter being added).
    @MainActor
    private func loadHistoryFromFile() async {
        let chronological: [HistoryItem]
        do {
            chronological = try await store.loadAll()
        } catch {
            print("⚠️ History load failed: \(error)")
            return
        }

        // Apply normalization once at load — any entries written before
        // we added the hallucination filter get cleaned up here. Items
        // whose normalized form is empty are dropped.
        let normalized = chronological.compactMap { item -> HistoryItem? in
            let cleaned = WhisperService.normalizedTranscription(from: item.transcript)
            guard !cleaned.isEmpty else { return nil }
            if cleaned == item.transcript { return item }
            return HistoryItem(
                id: item.id,
                date: item.date,
                transcript: cleaned,
                duration: item.duration,
                audioFileURL: item.audioFileURL,
                modelUsed: item.modelUsed,
                transcriptionTime: item.transcriptionTime
            )
        }

        // Items array is newest-first; file is oldest-first. Reverse.
        items = Array(normalized.reversed())

        // If normalization dropped or rewrote anything, persist the
        // cleaned snapshot back to the file so we don't repeat the
        // work next launch.
        if normalized.count != chronological.count
            || zip(chronological, normalized).contains(where: { $0.transcript != $1.transcript })
        {
            Task { try? await store.rewrite(normalized) }
        }

        migrateStatsIfNeeded(from: normalized)
    }

    private func loadStats() {
        if let data = UserDefaults.standard.data(forKey: statsSaveKey),
           let decoded = try? JSONDecoder().decode([HistoryStatsEntry].self, from: data) {
            statsEntries = decoded.sorted { $0.date > $1.date }
        }
    }
    
    private func migrateStatsIfNeeded(from historyItems: [HistoryItem]) {
        guard statsEntries.isEmpty, !historyItems.isEmpty else { return }

        statsEntries = historyItems.map { item in
            HistoryStatsEntry(
                id: item.id,
                date: item.date,
                wordCount: item.transcript
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .count,
                duration: item.duration
            )
        }
        saveStats()
    }
    
    private func filteredStatsEntries(since startDate: Date?) -> [HistoryStatsEntry] {
        guard let startDate else { return statsEntries }
        return statsEntries.filter { $0.date >= startDate }
    }

    private func removeAudioFileIfNeeded(for item: HistoryItem) {
        guard let audioFileURL = item.audioFileURL else { return }
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else { return }
        try? FileManager.default.removeItem(at: audioFileURL)
    }

#if DEBUG
    func resetAllDataForTesting() {
        items = []
        statsEntries = []
        UserDefaults.standard.removeObject(forKey: saveKey)
        UserDefaults.standard.removeObject(forKey: statsSaveKey)
    }
#endif
}
