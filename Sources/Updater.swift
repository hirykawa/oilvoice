import AppKit
import CryptoKit
import Security

/// GitHub Releases に新しい版があれば、ダウンロードしてアプリを入れ替え、起動し直す。
/// 設定・辞書・モデル・キーチェーン・許可はアプリの外にあるので、入れ替えてもそのまま残る。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repo = "hirykawa/oilvoice"
    /// リリースの zip は製品版なので、開発版から確かめるときも製品版の ID で見る
    nonisolated static let bundleID = "jp.contrea.oilvoice"

    struct Release {
        let version: String
        let notes: String
        let page: URL
        let zip: URL
        let zipName: String
        let sums: URL?
    }

    /// 見つかったが、まだ入れていない新しい版
    @Published private(set) var available: Release?
    @Published private(set) var status = ""
    @Published private(set) var busy = false

    private let d = UserDefaults.standard
    private var timer: Timer?

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: 確認

    /// 起動時に呼ぶ。少し待ってから確認し、その後も 1 日 1 回確認する。
    func start() {
        guard !AppInfo.isDev else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.autoCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoCheck() }
        }
    }

    private func autoCheck() {
        guard AppSettings.shared.autoCheckUpdates, !busy else { return }
        let last = d.object(forKey: "updateLastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    /// 新しい版を探す。userInitiated なら「最新です」やエラーも知らせる。
    func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        status = "確認中…"
        defer { busy = false }
        do {
            let r = try await Self.fetchLatest()
            d.set(Date(), forKey: "updateLastCheck")
            guard Self.isNewer(r.version, than: Self.currentVersion) else {
                available = nil
                status = "最新の版です（\(Self.currentVersion)）"
                if userInitiated { alert("OilVoice は最新の版です", "今の版：\(Self.currentVersion)") }
                return
            }
            available = r
            status = "新しい版があります（\(r.version)）"
            DebugLog.log("update: \(r.version) available")
            if !userInitiated && d.string(forKey: "updateSkippedVersion") == r.version { return }
            busy = false
            offer(r, userInitiated: userInitiated)
        } catch {
            status = "確認できませんでした：\(error.localizedDescription)"
            DebugLog.log("update check failed: \(error.localizedDescription)")
            if userInitiated { alert("アップデートを確認できませんでした", error.localizedDescription) }
        }
    }

    /// メニューから：見つかっている版を入れる
    func offerAvailable() {
        if let r = available { offer(r, userInitiated: true) }
    }

    private func offer(_ r: Release, userInitiated: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "OilVoice \(r.version) があります"
        var info = "今の版：\(Self.currentVersion)\n設定・辞書・モデルはそのまま引き継がれます。更新すると OilVoice が終了し、自動で起動し直します。"
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + (notes.count > 700 ? String(notes.prefix(700)) + "…" : notes) }
        a.informativeText = info
        a.addButton(withTitle: "今すぐ更新")
        a.addButton(withTitle: "あとで")
        if !userInitiated { a.addButton(withTitle: "この版をスキップ") }
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await install(r) }
        case .alertThirdButtonReturn: d.set(r.version, forKey: "updateSkippedVersion")
        default: break
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: 入れ替え

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func install(_ r: Release) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("OilVoiceUpdate-\(UUID().uuidString)")
        do {
            let target = Bundle.main.bundleURL
            guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw Failure(message: "\(target.deletingLastPathComponent().path) に書き込めないため、自動で更新できません。リリースのページからダウンロードしてください。")
            }
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

            status = "ダウンロード中…（\(r.version)）"
            let zip = tmp.appendingPathComponent(r.zipName)
            let (dl, resp) = try await URLSession.shared.download(from: r.zip)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "ダウンロードに失敗しました") }
            try fm.moveItem(at: dl, to: zip)

            status = "確認中…"
            try await Self.verifyChecksum(zip, name: r.zipName, sums: r.sums)
            let unpacked = tmp.appendingPathComponent("new")
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let newApp = unpacked.appendingPathComponent("OilVoice.app")
            try Self.verifyBundle(newApp, version: r.version)
            _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            // 終了を待って入れ替え、起動し直すスクリプト
            let script = tmp.appendingPathComponent("install.sh")
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path, tmp.path]
            try p.run()
            DebugLog.log("update: installing \(r.version) to \(target.path)")

            // 変更直後の設定も確実に残す
            AppSettings.shared.save()
            UserDefaults.standard.synchronize()
            NSApp.terminate(nil)
        } catch {
            try? fm.removeItem(at: tmp)
            status = "更新できませんでした：\(error.localizedDescription)"
            DebugLog.log("update failed: \(error.localizedDescription)")
            let a = NSAlert()
            a.messageText = "更新できませんでした"
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: "リリースのページを開く")
            a.addButton(withTitle: "閉じる")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.page) }
        }
    }

    /// $1=終了を待つ PID, $2=入れ替える .app, $3=新しい .app, $4=作業フォルダ
    nonisolated static let installScript = """
    #!/bin/sh
    PID="$1"; APP="$2"; NEW="$3"; TMP="$4"
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      sleep 0.2; i=$((i+1))
      [ "$i" -gt 300 ] && exit 1
    done
    OLD="$TMP/old.app"
    if mv "$APP" "$OLD"; then
      if mv "$NEW" "$APP"; then rm -rf "$OLD"; else mv "$OLD" "$APP"; fi
    fi
    open "$APP"
    case "$TMP" in */OilVoiceUpdate-*) rm -rf "$TMP" ;; esac
    """

    // MARK: 部品

    nonisolated static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OilVoice/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = j["assets"] as? [[String: Any]]
        else { throw Failure(message: "GitHub からリリースの情報を取得できませんでした") }
        func asset(_ match: (String) -> Bool) -> (String, URL)? {
            for a in assets {
                if let n = a["name"] as? String, match(n),
                   let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) { return (n, u) }
            }
            return nil
        }
        guard let zip = asset({ $0.hasSuffix("-macos-arm64.zip") }) else {
            throw Failure(message: "リリースにアプリの zip がありません")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: j["body"] as? String ?? "", page: page,
                       zip: zip.1, zipName: zip.0, sums: asset({ $0 == "SHA256SUMS.txt" })?.1)
    }

    /// "0.10.0" > "0.9.1" のように数字ごとに比べる
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    nonisolated static func verifyChecksum(_ file: URL, name: String, sums: URL?) async throws {
        guard let sums else { throw Failure(message: "リリースに SHA256SUMS.txt がありません") }
        let (data, _) = try await URLSession.shared.data(from: sums)
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.hasSuffix(" \(name)") || $0.hasSuffix("*\(name)") }),
              let expected = line.split(separator: " ").first.map({ $0.lowercased() })
        else { throw Failure(message: "SHA256SUMS.txt に \(name) がありません") }
        let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure(message: "ダウンロードしたファイルの SHA-256 が一致しません") }
    }

    /// バンドル ID・版・署名（指定要件）が正しいか
    nonisolated static func verifyBundle(_ app: URL, version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID
        else { throw Failure(message: "ダウンロードしたアプリが OilVoice ではありません") }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw Failure(message: "ダウンロードしたアプリの版が \(version) ではありません")
        }
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("identifier \"\(bundleID)\"" as CFString, [], &req) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), req) == errSecSuccess
        else { throw Failure(message: "ダウンロードしたアプリの署名を確認できませんでした") }
    }

    @discardableResult
    nonisolated static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure(message: "\(URL(fileURLWithPath: path).lastPathComponent) が失敗しました（\(p.terminationStatus)）")
        }
        return p.terminationStatus
    }
}
