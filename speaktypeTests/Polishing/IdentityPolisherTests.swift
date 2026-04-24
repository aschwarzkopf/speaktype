import XCTest
@testable import speaktype

/// Tests for IdentityPolisher — the no-op pass-through used by
/// CleanupMode.off and as a placeholder for .local / .cloud until
/// Phases 2 and 3 plug in the real implementations.
///
/// Contract: IdentityPolisher must return the input unchanged, byte for
/// byte, including leading/trailing whitespace and any internal
/// formatting. This makes it safe as the factory's fallback for modes
/// whose real implementations aren't yet built.
final class IdentityPolisherTests: XCTestCase {

    func testReturnsInputUnchanged() async throws {
        let polisher = IdentityPolisher()
        let result = try await polisher.polish("hello world")
        XCTAssertEqual(result, "hello world")
    }

    func testPreservesEmptyString() async throws {
        let polisher = IdentityPolisher()
        let result = try await polisher.polish("")
        XCTAssertEqual(result, "")
    }

    func testPreservesWhitespaceAndPunctuation() async throws {
        let polisher = IdentityPolisher()
        let noisy = "  um, so like,  I was thinking...  "
        let result = try await polisher.polish(noisy)
        XCTAssertEqual(result, noisy,
            "IdentityPolisher must be byte-for-byte identity — it is not allowed to " +
            "preemptively trim, normalize, or collapse anything. That's the real " +
            "polishers' job.")
    }

    func testPreservesMultilineContent() async throws {
        let polisher = IdentityPolisher()
        let multiline = "first line\n\nsecond line with CRLF\r\nthird line"
        let result = try await polisher.polish(multiline)
        XCTAssertEqual(result, multiline)
    }

    func testPreservesUnicode() async throws {
        let polisher = IdentityPolisher()
        let unicode = "こんにちは 🎙️ café naïve"
        let result = try await polisher.polish(unicode)
        XCTAssertEqual(result, unicode)
    }
}
