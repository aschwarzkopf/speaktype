import XCTest
@testable import speaktype

/// Tests for ClaudeAPIKeyStore — the Keychain wrapper that persists
/// the user's Anthropic API key across launches.
///
/// Each test uses a unique service+account combination via the
/// injectable initializer so we don't collide with the production key
/// store or with each other on parallel test runs.
final class ClaudeAPIKeyStoreTests: XCTestCase {

    private func makeStore(_ suffix: String = UUID().uuidString) -> ClaudeAPIKeyStore {
        ClaudeAPIKeyStore(
            service: "com.2048labs.speaktype.tests.\(suffix)",
            account: "test-account"
        )
    }

    override func tearDown() {
        super.tearDown()
        // Best-effort: each test's unique service should already prevent
        // collisions, but if a test leaks a key it stays scoped to a
        // disposable service name that real production code never queries.
    }

    // MARK: - Round-trip

    func testSaveAndLoad() throws {
        let store = makeStore()
        try store.save("sk-ant-api03-test-key-abc123")
        XCTAssertEqual(store.load(), "sk-ant-api03-test-key-abc123")
    }

    func testLoadReturnsNilWhenNothingStored() {
        let store = makeStore()
        XCTAssertNil(store.load())
    }

    func testHasKeyReflectsStorage() throws {
        let store = makeStore()
        XCTAssertFalse(store.hasKey)
        try store.save("sk-ant-test")
        XCTAssertTrue(store.hasKey)
    }

    // MARK: - Update

    func testSavingNewKeyOverwritesPreviousOne() throws {
        let store = makeStore()
        try store.save("first-key")
        try store.save("second-key")
        XCTAssertEqual(store.load(), "second-key",
            "Save must overwrite — Keychain has SecItemAdd-fails-if-exists semantics " +
            "by default, so the implementation must delete first.")
    }

    // MARK: - Delete

    func testDeleteRemovesStoredKey() throws {
        let store = makeStore()
        try store.save("temporary")
        try store.delete()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasKey)
    }

    func testDeleteWhenNothingStoredIsNoOp() throws {
        let store = makeStore()
        // Must not throw — calling delete on an absent key is fine.
        XCTAssertNoThrow(try store.delete())
    }

    // MARK: - Whitespace handling

    func testSaveTrimsWhitespace() throws {
        // User-friendly: pasted keys often carry trailing newlines.
        let store = makeStore()
        try store.save("  sk-ant-test\n  ")
        XCTAssertEqual(store.load(), "sk-ant-test")
    }

    func testSaveRejectsEmptyOrWhitespaceOnly() {
        let store = makeStore()
        XCTAssertThrowsError(try store.save(""))
        XCTAssertThrowsError(try store.save("    \n\t"))
    }
}
