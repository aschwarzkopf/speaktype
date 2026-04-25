import Foundation

/// Cloud transcript cleanup using Anthropic's Claude API.
///
/// No official Anthropic Swift SDK exists as of 2026 — the production
/// pattern (used by MacWhisper, BoltAI, Raycast extensions) is raw
/// URLSession against `/v1/messages`. The user supplies their own API
/// key via the Cleanup tab; this code never sees Anthropic's billing.
///
/// Failures fall back to the raw transcript so cleanup never blocks
/// paste:
///   - 401 (bad key) → raw, no retry (retrying won't fix a bad key)
///   - 429 (rate-limited) → one retry with 800ms backoff, then raw
///   - 529 (overloaded) → one retry with 800ms backoff, then raw
///   - Network error → raw
///   - 4xx other / 5xx other → raw
///
/// Uses non-streaming responses — auto-paste needs the complete string,
/// streaming would just add SSE-parsing complexity for zero UX gain at
/// these short prompt sizes (~1.5s typical end-to-end).
struct ClaudePolisher: TranscriptPolisher {

    /// Anthropic model. Pinned to a specific Sonnet release for
    /// stability; bump when upgrading. (claude-sonnet-4-5 is the
    /// shipping Sonnet as of early 2026.)
    static let model = "claude-sonnet-4-5"

    /// Anthropic API endpoint for chat-style messages.
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// API version header. Anthropic's API uses dated versioning;
    /// 2023-06-01 is the long-stable production version.
    static let apiVersion = "2023-06-01"

    /// Same instructions as FoundationModelsPolisher for consistency
    /// of behavior across providers — switching modes shouldn't change
    /// what cleanup does, only how fast / where it runs.
    static let systemPrompt = """
        You clean up voice-dictation transcripts. Remove filler words \
        (um, uh, ah, er, like, you know), collapse stutters (I-I-I → I), \
        and fix punctuation and capitalization. Do NOT rephrase, \
        summarize, or change meaning. Preserve the speaker's exact word \
        choice otherwise. If uncertain whether a word is filler, KEEP \
        it. Output only the cleaned transcript, no preamble.
        """

    static let minimumWordCount = 5
    static let maxTokens = 1024
    static let timeout: TimeInterval = 30
    static let retryDelay: TimeInterval = 0.8

    let apiKey: String
    let urlSession: URLSession

    init(apiKey: String, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    func polish(_ raw: String) async throws -> String {
        let words = raw.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= Self.minimumWordCount else { return raw }

        try Task.checkCancellation()
        let request = try buildRequest(forRawText: raw)

        // Try once, retry once on transient (429/529 / network), then raw.
        for attempt in 0..<2 {
            try Task.checkCancellation()

            let outcome = await performRequest(request)
            switch outcome {
            case .success(let cleaned):
                return cleaned.isEmpty ? raw : cleaned
            case .badKey, .clientError, .serverError:
                return raw
            case .transient:
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                    continue
                }
                return raw
            case .networkError:
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                    continue
                }
                return raw
            }
        }
        return raw
    }

    // MARK: - Request

    private func buildRequest(forRawText raw: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": Self.maxTokens,
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": raw]
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response classification

    private enum Outcome {
        case success(String)
        case badKey       // 401 — never retry
        case clientError  // other 4xx — never retry (probably our bug)
        case transient    // 429, 529 — retry once
        case serverError  // other 5xx — never retry
        case networkError // URLSession threw
    }

    private func performRequest(_ request: URLRequest) async -> Outcome {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .networkError
            }
            switch http.statusCode {
            case 200:
                return .success(parseSuccess(data) ?? "")
            case 401:
                return .badKey
            case 429, 529:
                return .transient
            case 400...499:
                return .clientError
            case 500...599:
                return .serverError
            default:
                return .clientError
            }
        } catch is CancellationError {
            // Re-thrown by the caller via try Task.checkCancellation()
            // before each attempt.
            return .networkError
        } catch {
            return .networkError
        }
    }

    private func parseSuccess(_ data: Data) -> String? {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        struct Response: Decodable {
            let content: [ContentBlock]
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.content.first(where: { $0.type == "text" })?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
