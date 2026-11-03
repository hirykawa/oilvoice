import CryptoKit
import Foundation

/// モデルファイルを Hugging Face から取得して ~/Library/Application Support/OilVoice/Models に置く。
/// Haas-ja-v1.0 GGUF（Apache-2.0）と Silero VAD GGUF（MIT）。どちらも固定リビジョンと SHA-256 で確認する。
final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelManager()

    static let haasRepo = "sakasegawa/Haas-ja-v1.0-GGUF"
    static let haasRevision = "6b965d5007ba780585de51549d57a8c1c0d67c7e"
    static let vadRepo = "sakasegawa/silero-vad-GGUF"
    static let vadRevision = "7fcb7aa2a70c312f8579fc987b3e1cdecf9321ca"
    static let vadFile = "silero-vad-309K-v6.2-F32.gguf"
    static let vadSHA = "2fc312514e5fc4fa4ffd02b25c76a4853fa4130e8fb9777d01502183b01238cb"

    enum State: Equatable {
        case idle
        case downloading(String, Double)
        case verifying(String)
        case ready
        case failed(String)
    }

    @Published var state: State = .idle

    let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OilVoice/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func path(for variant: ModelVariant) -> URL { directory.appendingPathComponent(variant.fileName) }
    var vadPath: URL { directory.appendingPathComponent(Self.vadFile) }

    func isInstalled(_ variant: ModelVariant) -> Bool {
        let p = path(for: variant).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let size = attrs[.size] as? Int64 else { return false }
        return size == variant.size
    }

    var vadInstalled: Bool { FileManager.default.fileExists(atPath: vadPath.path) }

    // MARK: - ダウンロード

    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var currentLabel = ""

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    /// 必要なファイルを揃える。揃っていれば何もしない。
    func ensure(_ variant: ModelVariant) async throws {
        if !vadInstalled {
            try await fetch(repo: Self.vadRepo, revision: Self.vadRevision, file: Self.vadFile,
                            sha: Self.vadSHA, to: vadPath, label: "音声区間検出モデル")
        }
        if !isInstalled(variant) {
            try await fetch(repo: Self.haasRepo, revision: Self.haasRevision, file: variant.fileName,
                            sha: variant.sha256, to: path(for: variant), label: "Haas-ja \(variant.rawValue.uppercased())")
        }
        await MainActor.run { self.state = .ready }
    }

    func delete(_ variant: ModelVariant) {
        try? FileManager.default.removeItem(at: path(for: variant))
        objectWillChange.send()
    }

    private func fetch(repo: String, revision: String, file: String, sha: String, to dest: URL, label: String) async throws {
        let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")!
        currentLabel = label
        await MainActor.run { self.state = .downloading(label, 0) }
        let tmp: URL = try await withCheckedThrowingContinuation { c in
            self.continuation = c
            self.session.downloadTask(with: url).resume()
        }
        await MainActor.run { self.state = .verifying(label) }
        let digest = try Self.sha256(of: tmp)
        guard digest == sha else {
            try? FileManager.default.removeItem(at: tmp)
            let msg = "\(label) の SHA-256 が一致しません"
            await MainActor.run { self.state = .failed(msg) }
            throw NSError(domain: "OilVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let label = currentLabel
        DispatchQueue.main.async { self.state = .downloading(label, p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // location は戻ると消えるので、すぐに退避する
        let keep = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            continuation?.resume(throwing: NSError(domain: "OilVoice", code: http.statusCode,
                                                   userInfo: [NSLocalizedDescriptionKey: "ダウンロードに失敗しました（HTTP \(http.statusCode)）"]))
            continuation = nil
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            continuation?.resume(returning: keep)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let msg = error.localizedDescription
        DispatchQueue.main.async { self.state = .failed(msg) }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
