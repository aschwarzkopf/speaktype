import XCTest
@testable import speaktype

/// Tests for HistoryStore — the NDJSON append-only file store that
/// replaces UserDefaults as the persistence layer for transcription
/// history. Each test gets a unique temp directory so they can run in
/// parallel without contaminating each other or the dev's real data.
final class HistoryStoreTests: XCTestCase {

    var tempDirectory: URL!
    var store: HistoryStore!

    override func setUp() async throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-store-test-\(UUID().uuidString)")
        store = HistoryStore(directory: tempDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeItem(_ transcript: String) -> HistoryItem {
        HistoryItem(
            id: UUID(),
            date: Date(),
            transcript: transcript,
            duration: 1.5,
            audioFileURL: nil,
            modelUsed: "test-model",
            transcriptionTime: 0.3
        )
    }

    // MARK: - Empty state

    func testLoadEmptyStoreReturnsEmpty() async throws {
        let result = try await store.loadAll()
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - Append + load round-trip

    func testAppendAndLoadSingleItem() async throws {
        let item = makeItem("hello world")
        try await store.append(item)
        let result = try await store.loadAll()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].transcript, "hello world")
        XCTAssertEqual(result[0].id, item.id)
    }

    func testAppendMultipleItemsPreservesOrder() async throws {
        let items = (0..<5).map { makeItem("entry \($0)") }
        for item in items {
            try await store.append(item)
        }
        let result = try await store.loadAll()
        XCTAssertEqual(result.count, 5)
        // File is chronological — first appended is first in load order
        for (idx, item) in items.enumerated() {
            XCTAssertEqual(result[idx].transcript, item.transcript)
        }
    }

    // MARK: - Crash recovery — torn writes / malformed lines

    func testLoadIgnoresMalformedLines() async throws {
        // Hand-craft a file with a torn line at the end (simulates SIGKILL
        // mid-write) plus a valid line. Loader should yield the valid
        // entries and silently drop the torn one.
        let valid = makeItem("survived crash")
        try await store.append(valid)

        let fileURL = tempDirectory.appendingPathComponent("history.ndjson")
        let existing = try Data(contentsOf: fileURL)
        let augmented = existing + "{\"id\":\"truncated".data(using: .utf8)!
        try augmented.write(to: fileURL, options: .atomic)

        let result = try await store.loadAll()
        XCTAssertEqual(result.count, 1,
            "Torn final line from a crash must be silently dropped, not crash the loader.")
        XCTAssertEqual(result[0].transcript, "survived crash")
    }

    func testLoadIgnoresBlankLines() async throws {
        let item = makeItem("real entry")
        try await store.append(item)

        let fileURL = tempDirectory.appendingPathComponent("history.ndjson")
        let existing = try Data(contentsOf: fileURL)
        // Append a couple of empty lines + a real second entry to test
        // that blank-line tolerance works mid-file too.
        let item2 = makeItem("second entry")
        var augmented = existing
        augmented.append("\n\n".data(using: .utf8)!)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        augmented.append(try encoder.encode(item2))
        augmented.append("\n".data(using: .utf8)!)
        try augmented.write(to: fileURL, options: .atomic)

        let result = try await store.loadAll()
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Rewrite (used by delete / compaction)

    func testRewriteReplacesAllContent() async throws {
        try await store.append(makeItem("a"))
        try await store.append(makeItem("b"))
        try await store.append(makeItem("c"))

        let kept = [makeItem("only this one survives")]
        try await store.rewrite(kept)

        let result = try await store.loadAll()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].transcript, "only this one survives")
    }

    func testRewriteWithEmptyArrayProducesEmptyFile() async throws {
        try await store.append(makeItem("temp"))
        try await store.rewrite([])
        let result = try await store.loadAll()
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - File format invariants

    func testFileHasOneEntryPerLine() async throws {
        let items = (0..<3).map { makeItem("entry-\($0)") }
        for item in items {
            try await store.append(item)
        }

        let fileURL = tempDirectory.appendingPathComponent("history.ndjson")
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3,
            "NDJSON contract: one JSON object per line, exactly 3 lines for 3 items.")

        // Each line must be a valid standalone JSON object.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            guard let data = line.data(using: .utf8) else {
                XCTFail("Failed to convert line to data")
                continue
            }
            XCTAssertNoThrow(try decoder.decode(HistoryItem.self, from: data))
        }
    }

    func testFileEndsWithNewline() async throws {
        try await store.append(makeItem("x"))
        let fileURL = tempDirectory.appendingPathComponent("history.ndjson")
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(raw.hasSuffix("\n"),
            "NDJSON files end with a newline so subsequent appends start cleanly.")
    }

    // MARK: - Directory creation

    func testCreatesDirectoryOnFirstWrite() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path),
            "Sanity: directory does not exist before first append.")
        try await store.append(makeItem("initial"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.path),
            "First append must create the directory automatically.")
    }
}
