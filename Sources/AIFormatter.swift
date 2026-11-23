import Foundation

/// AI 整形。ChatGPT（Codex のバックエンド、サブスク枠）に投げる。
enum AIFormatter {
    static let chatgptModels = ["gpt-5.6-luna", "gpt-6-luna", "gpt-5.6-terra", "gpt-6.1-terra", "gpt-5.6-sol", "gpt-6-sol", "gpt-6.1-sol"]

    static func isAvailable(_ s: AppSettings) -> Bool {
        switch s.aiProvider {
        case .none: return false
        case .chatgpt: return ChatGPTAuth.shared.isLoggedIn
        }
    }

    static func systemPrompt(_ s: AppSettings) -> String {
        var p = s.aiPrompt
        let words = s.dictionary.map(\.written).filter { !$0.isEmpty }
        if !words.isEmpty {
            p += "\n- 次の語はこの表記で書く: " + words.joined(separator: "、")
        }
        return p
    }

    /// 整形する。失敗したら例外。
    static func format(_ text: String, settings s: AppSettings) async throws -> String {
        let out: String
        switch s.aiProvider {
        case .none: return text
        case .chatgpt: out = try await chatgpt(text, s)
        }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? text : t
    }

    /// タイムアウト付き
    static func formatWithTimeout(_ text: String, settings s: AppSettings) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { g in
            g.addTask { try await format(text, settings: s) }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(s.aiTimeout * 1e9))
                throw SpeechEngine.Failure(message: "AI 整形がタイムアウトしました")
            }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    // MARK: ChatGPT（Responses API、ストリーミング必須）

    private static func chatgpt(_ text: String, _ s: AppSettings) async throws -> String {
        let t = try await ChatGPTAuth.shared.validTokens()
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(t.accessToken)", forHTTPHeaderField: "Authorization")
        if let a = t.accountID { req.setValue(a, forHTTPHeaderField: "chatgpt-account-id") }
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": s.chatgptModel,
            "instructions": systemPrompt(s),
            "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]],
            "tools": [],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
        ]
        if !s.chatgptReasoning.isEmpty { body["reasoning"] = ["effort": s.chatgptReasoning] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var err = ""
            for try await line in bytes.lines { err += line; if err.count > 400 { break } }
            throw SpeechEngine.Failure(message: "ChatGPT: HTTP \(code) \(err.prefix(300))")
        }
        var out = ""
        var completed: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = payload.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = j["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                out += j["delta"] as? String ?? ""
            case "response.output_text.done":
                completed = j["text"] as? String
            case "response.completed":
                return completed ?? out
            case "response.failed", "error":
                let msg = ((j["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                    ?? (j["message"] as? String) ?? "失敗しました"
                throw SpeechEngine.Failure(message: "ChatGPT: \(msg)")
            default: break
            }
        }
        return completed ?? out
    }
}
