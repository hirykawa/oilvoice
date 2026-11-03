import Foundation

/// speech.cpp（MIT）の C API を包む。認識モデル Haas-ja-v1.0 と Silero VAD を1つずつ持つ。
/// speech.cpp のモデルは同時に1リクエストしか処理しないので、呼び出しはすべて `queue` に直列化する。
final class SpeechEngine {
    static let shared = SpeechEngine()
    static let sampleRate = 16_000

    let queue = DispatchQueue(label: "oilvoice.asr", qos: .userInitiated)
    private var asr: OpaquePointer?
    private var vad: OpaquePointer?
    private(set) var loadedPath: String?

    private let flagLock = NSLock()
    private var loadedFlag = false
    /// 読み込み済みか（認識キューを待たずに読める）
    var isLoaded: Bool { flagLock.lock(); defer { flagLock.unlock() }; return loadedFlag }
    private func setLoaded(_ v: Bool) { flagLock.lock(); loadedFlag = v; flagLock.unlock() }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func check(_ status: speech_status, _ what: String) throws {
        if status.rawValue < 0 {
            let detail = speech_last_error().map { String(cString: $0) } ?? ""
            let name = String(cString: speech_status_name(status))
            throw Failure(message: "\(what): \(name) \(detail)")
        }
    }

    /// モデルを読み込む（既に同じものを読んでいれば何もしない）。GPU（Metal）を使い、起動時にウォームアップする。
    func load(asrPath: String, vadPath: String) throws {
        try queue.sync {
            if loadedPath == asrPath, asr != nil, vad != nil { return }
            setLoaded(false)
            if let a = asr { speech_model_free(a); asr = nil }
            if let v = vad { speech_model_free(v); vad = nil }

            var params: OpaquePointer?
            try Self.check(speech_load_params_new(&params), "load params")
            defer { speech_load_params_free(params) }
            _ = speech_load_params_set_warmup(params, 1)

            var a: OpaquePointer?
            try Self.check(speech_model_load(asrPath, params, &a), "音声認識モデルの読み込み")
            var v: OpaquePointer?
            do {
                // VAD は小さいので CPU で十分（GPU の取り合いを避ける）
                var vp: OpaquePointer?
                try Self.check(speech_load_params_new(&vp), "load params")
                defer { speech_load_params_free(vp) }
                _ = speech_load_params_set_device(vp, "cpu")
                _ = speech_load_params_set_threads(vp, 1)
                try Self.check(speech_model_load(vadPath, vp, &v), "音声区間検出モデルの読み込み")
            } catch {
                speech_model_free(a)
                throw error
            }
            asr = a
            vad = v
            loadedPath = asrPath
            setLoaded(true)
        }
    }

    func unload() {
        setLoaded(false)
        queue.sync {
            if let a = asr { speech_model_free(a); asr = nil }
            if let v = vad { speech_model_free(v); vad = nil }
            loadedPath = nil
        }
    }

    // MARK: - 認識（queue の上で呼ぶ）

    /// 16 kHz モノラルの音声を認識する。`queue` 上から呼ぶこと。
    func transcribeOnQueue(_ samples: UnsafeBufferPointer<Float>, keywords: String, alpha: Double) throws -> String {
        guard let asr else { throw Failure(message: "モデルが読み込まれていません") }
        // 20 ms 未満は受け付けないので、短すぎるものは空とする
        guard samples.count >= Self.sampleRate / 20 else { return "" }
        var req: OpaquePointer?
        try Self.check(speech_request_new(asr, &req), "request")
        defer { speech_request_free(req) }
        try Self.check(speech_request_set_audio(req, samples.baseAddress, samples.count, Int32(Self.sampleRate)), "audio")
        if !keywords.isEmpty {
            try Self.check(speech_request_set_string(req, SPEECH_OPT_KEYWORDS, keywords), "keywords")
            try Self.check(speech_request_set_float(req, SPEECH_OPT_KEYWORDS_ALPHA, alpha), "keywords_alpha")
        }
        try Self.check(speech_transcribe(req), "認識")
        guard let result = speech_request_result(req), let t = speech_result_text(result) else { return "" }
        return String(cString: t)
    }

    func transcribe(_ samples: [Float], keywords: String, alpha: Double) throws -> String {
        try queue.sync {
            try samples.withUnsafeBufferPointer { try transcribeOnQueue($0, keywords: keywords, alpha: alpha) }
        }
    }

    /// 録音全体から話している区間を探す（ファイルの文字起こし用）
    func detectRegions(_ samples: [Float], maxSpeech: Double = 20) throws -> [(Double, Double)] {
        try queue.sync {
            guard let vad else { throw Failure(message: "モデルが読み込まれていません") }
            var req: OpaquePointer?
            try Self.check(speech_request_new(vad, &req), "request")
            defer { speech_request_free(req) }
            try samples.withUnsafeBufferPointer {
                try Self.check(speech_request_set_audio(req, $0.baseAddress, $0.count, Int32(Self.sampleRate)), "audio")
            }
            _ = speech_request_set_float(req, SPEECH_OPT_MAX_SPEECH_DURATION_S, maxSpeech)
            try Self.check(speech_detect(req), "区間検出")
            guard let result = speech_request_result(req) else { return [] }
            var out: [(Double, Double)] = []
            for i in 0..<speech_result_segment_count(result) {
                var s = 0.0, e = 0.0
                if speech_result_segment(result, i, &s, &e, nil).rawValue >= 0 { out.append((s, e)) }
            }
            return out
        }
    }

    // MARK: - 届いた音声の区間検出（ライブ入力用）

    /// 逐次の VAD。`queue` 上で使う。
    final class LiveDetector {
        private var det: OpaquePointer?
        private(set) var given = 0

        init(engine: SpeechEngine) throws {
            guard let vad = engine.vad else { throw Failure(message: "モデルが読み込まれていません") }
            var req: OpaquePointer?
            try SpeechEngine.check(speech_request_new(vad, &req), "request")
            defer { speech_request_free(req) }
            _ = speech_request_set_int(req, SPEECH_OPT_MIN_SILENCE_DURATION_MS, 450)
            _ = speech_request_set_int(req, SPEECH_OPT_SPEECH_PAD_MS, 150)
            _ = speech_request_set_float(req, SPEECH_OPT_MAX_SPEECH_DURATION_S, 120)
            try SpeechEngine.check(speech_detection_start(req, Int32(SpeechEngine.sampleRate), &det), "検出開始")
        }

        deinit { speech_detection_free(det) }

        func push(_ samples: UnsafeBufferPointer<Float>) {
            guard samples.count > 0 else { return }
            _ = speech_detection_push(det, samples.baseAddress, samples.count)
        }

        func end() { _ = speech_detection_end(det) }

        /// まだ受け取っていない確定区間
        func takeNewRegions() -> [(Double, Double)] {
            var out: [(Double, Double)] = []
            let n = speech_detection_region_count(det)
            while given < n {
                var s = 0.0, e = 0.0
                if speech_detection_region(det, given, &s, &e).rawValue >= 0 { out.append((s, e)) }
                given += 1
            }
            return out
        }

        /// 話し中の区間の開始時刻
        func speakingStart() -> Double? {
            var s = 0.0
            var kept: Int32 = 0
            return speech_detection_speaking(det, &s, &kept) != 0 ? s : nil
        }
    }
}
