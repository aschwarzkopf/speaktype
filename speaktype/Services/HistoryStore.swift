import Foundation

/// Append-only NDJSON file store for transcription history. Replaces
/// the previous UserDefaults-based persistence which lost data on
/// abrupt termination (e.g. `make build` killing the running app via
/// SIGKILL before UserDefaults flushed its in-memory write buffer).
///
/// Format: one `HistoryItem` per line, JSON-encoded with ISO-8601
/// dates. Lines end with `\n`. Common in production logging /
/// event-stream tools (jq, fluentd, Datadog) — debuggable in any text
/// editor or via `tail -f`.
///
/// Durability:
///   - `append` uses `FileHandle.seekToEnd` + `write` for O(1) appends
///   - `rewrite` (delete / compaction) uses `Data.write(.atomic)` which
///     writes-temp + rename — POSIX-atomic on APFS, survives SIGKILL
///   - Torn final lines from crash mid-write are silently dropped on
///     load (the JSON decoder rejects them; valid lines before survive)
///
/// Concurrency: actor-isolated — all reads and writes serialize through
/// the actor, no torn intra-process writes possible. Cross-process
/// scenarios aren't supported (we're a single-instance Mac app).
///
/// Testing: callers inject `directory` so tests can use a temp dir per
/// case without contaminating the dev's real Application Support.
actor HistoryStore {
    let directory: URL
    private let fileName = "history.ndjson"

    var fileURL: URL {
        directory.appendingPathComponent(fileName)
    }

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Public API

    /// Append a single item to the file. Creates the directory and
    /// file on first call.
    func append(_ item: HistoryItem) throws {
        try ensureDirectoryExists()
        let line = try Self.encodeLine(item)
        try Self.appendLine(line, to: fileURL)
    }

    /// Load every item from disk, in chronological order (oldest first
    /// as appended). Malformed / torn lines are silently dropped.
    func loadAll() throws -> [HistoryItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return Self.parseLines(data)
    }

    /// Replace the entire file's contents atomically. Used for deletions
    /// and compaction; rewrite-on-every-save is too expensive for
    /// frequent appends.
    func rewrite(_ items: [HistoryItem]) throws {
        try ensureDirectoryExists()
        var body = ""
        for item in items {
            body += try Self.encodeLine(item) + "\n"
        }
        let data = body.data(using: .utf8) ?? Data()
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Helpers

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Encode a single item as a one-line JSON string (no embedded
    /// newlines, since those would break the NDJSON contract).
    static func encodeLine(_ item: HistoryItem) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // `.sortedKeys` keeps output stable for diff / debug; otherwise
        // dictionaries serialize in arbitrary order each run.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(item)
        // JSONEncoder won't produce raw newlines for normal data, but
        // assert defensively to catch any future regression at the
        // encode site rather than corrupting the file.
        guard let raw = String(data: data, encoding: .utf8),
            !raw.contains("\n")
        else {
            throw EncodingError.invalidValue(item, .init(
                codingPath: [],
                debugDescription: "Encoded line contains an embedded newline."
            ))
        }
        return raw
    }

    static func appendLine(_ line: String, to fileURL: URL) throws {
        let bytes = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } else {
            try bytes.write(to: fileURL, options: .atomic)
        }
    }

    static func parseLines(_ data: Data) -> [HistoryItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var result: [HistoryItem] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                let lineData = trimmed.data(using: .utf8)
            else { continue }
            // Silently skip lines that fail to decode — torn writes from
            // a crash mid-append leave the last line truncated, and we
            // don't want one bad line to fail the whole load.
            if let item = try? decoder.decode(HistoryItem.self, from: lineData) {
                result.append(item)
            }
        }
        return result
    }
}
