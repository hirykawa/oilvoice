import AppKit
import CryptoKit
import Foundation
import Network

/// ChatGPT アカウントでのログイン（Codex CLI と同じ OAuth 2.0 + PKCE）。
/// ログインすると ChatGPT の Plus / Pro などのサブスク枠で Codex のモデルを呼べる。
final class ChatGPTAuth: ObservableObject {
    static let shared = ChatGPTAuth()

    static let issuer = "https://auth.openai.com"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let port: UInt16 = 1455
    static let redirectURI = "http://127.0.0.1:1455/auth/callback"

    struct Tokens: Codable {
        var idToken: String
        var accessToken: String
        var refreshToken: String
        var accountID: String?
        var email: String?
        var expiresAt: Date?
    }

    @Published private(set) var tokens: Tokens?
    @Published var status: String = ""

    var isLoggedIn: Bool { tokens != nil }

    private var listener: NWListener?
    private var pkceVerifier = ""
    private var oauthState = ""

    private init() {
        if let s = Keychain.get("chatgpt.tokens"), let d = s.data(using: .utf8) {
            tokens = try? JSONDecoder().decode(Tokens.self, from: d)
        }
    }

    private func persist() {
        if let t = tokens, let d = try? JSONEncoder().encode(t) {
            Keychain.set("chatgpt.tokens", String(data: d, encoding: .utf8))
        } else {
            Keychain.set("chatgpt.tokens", nil)
        }
    }

    func logout() {
        tokens = nil
        persist()
        status = "ログアウトしました"
    }

    // MARK: - ログイン

    func login() {
        stopListener()
        pkceVerifier = Self.randomURLSafe(64)
        oauthState = Self.randomURLSafe(32)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(pkceVerifier.utf8))))

        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.start(queue: .main)
            listener = l
        } catch {
            status = "ポート \(Self.port) を開けませんでした（Codex のログイン画面が開いていませんか）"
            return
        }

        var c = URLComponents(string: "\(Self.issuer)/oauth/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: oauthState),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        status = "ブラウザでログインしてください…"
        NSWorkspace.shared.open(c.url!)
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let url = URLComponents(string: "http://localhost\(parts[1])"),
                  url.path == "/auth/callback" else {
                self.respond(conn, 404, "Not Found")
                return
            }
            let q = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if let err = q["error"] {
                self.respond(conn, 400, "ログインできませんでした: \(err)")
                self.status = "ログインできませんでした: \(err)"
                self.stopListener()
                return
            }
            guard q["state"] == self.oauthState, let code = q["code"], !code.isEmpty else {
                self.respond(conn, 400, "state が一致しません")
                return
            }
            self.respond(conn, 200, "OilVoice にログインしました。このタブは閉じてかまいません。")
            self.stopListener()
            Task { await self.exchange(code: code) }
        }
    }

    private func respond(_ conn: NWConnection, _ code: Int, _ message: String) {
        let body = """
        <!doctype html><meta charset="utf-8"><title>OilVoice</title>
        <body style="font-family:-apple-system;display:grid;place-items:center;height:90vh;background:#111;color:#eee">
        <p style="font-size:18px">\(message)</p></body>
        """
        let resp = "HTTP/1.1 \(code) OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func exchange(code: String) async {
        var req = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": pkceVerifier,
        ])
        do {
            let t = try await tokenRequest(req, previousRefresh: nil)
            await MainActor.run {
                self.tokens = t
                self.persist()
                self.status = "ログインしました\(t.email.map { "（\($0)）" } ?? "")"
                NSApp.activate(ignoringOtherApps: true)
            }
        } catch {
            await MainActor.run { self.status = "トークンを取得できませんでした: \(error.localizedDescription)" }
        }
    }

    private func tokenRequest(_ req: URLRequest, previousRefresh: String?) async throws -> Tokens {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpeechEngine.Failure(message: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
        }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let access = j["access_token"] as? String else { throw SpeechEngine.Failure(message: "access_token がありません") }
        let idToken = j["id_token"] as? String ?? tokens?.idToken ?? ""
        let refresh = j["refresh_token"] as? String ?? previousRefresh ?? ""
        let claims = Self.jwtClaims(idToken)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let account = auth?["chatgpt_account_id"] as? String ?? tokens?.accountID
        let email = claims["email"] as? String ?? tokens?.email
        var expires: Date?
        if let exp = Self.jwtClaims(access)["exp"] as? Double { expires = Date(timeIntervalSince1970: exp) }
        else if let sec = j["expires_in"] as? Double { expires = Date().addingTimeInterval(sec) }
        return Tokens(idToken: idToken, accessToken: access, refreshToken: refresh, accountID: account, email: email, expiresAt: expires)
    }

    /// 有効なアクセストークンを返す（期限が近ければ更新する）
    func validTokens() async throws -> Tokens {
        guard var t = tokens else { throw SpeechEngine.Failure(message: "ChatGPT にログインしていません") }
        if let exp = t.expiresAt, exp.timeIntervalSinceNow > 300 { return t }
        var req = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": t.refreshToken,
            "scope": "openid profile email",
        ])
        t = try await tokenRequest(req, previousRefresh: t.refreshToken)
        let newTokens = t
        await MainActor.run { self.tokens = newTokens; self.persist() }
        return t
    }

    // MARK: - 補助

    static func jwtClaims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomURLSafe(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return base64url(Data(b))
    }

    static func form(_ dict: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(dict.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").utf8)
    }
}
