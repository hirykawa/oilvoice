import AVFoundation
import Foundation

/// マイクの音を 16 kHz モノラル float に変換して溜める。マイクは録音している間だけ開く。
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    /// 録音中（samples に溜めている）か
    private(set) var isRunning = false
    /// マイク（AVAudioEngine）が動いているか
    private var engineRunning = false
    /// 直近の音量（0〜1）。ゲージ表示用。
    private(set) var level: Float = 0
    private var convertFailures = 0
    /// 区間内の最大 RMS（ログ用、読むと 0 に戻る）
    var peak: Float = 0
    func takePeak() -> Float { let p = peak; peak = 0; return p }

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechEngine.sampleRate),
                                       channels: 1, interleaved: false)!

    private var isFeed: Bool { ProcessInfo.processInfo.environment["OILVOICE_FEED"] != nil }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - マイク

    private func startEngine() throws {
        guard !engineRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechEngine.Failure(message: "マイクが見つかりません")
        }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        engineRunning = true
        DebugLog.log("recorder: engine started, input \(format.sampleRate) Hz \(format.channelCount) ch, device \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "?")")
    }

    private func stopEngine() {
        guard engineRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
        DebugLog.log("recorder: engine stopped")
    }

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 60)
        lock.unlock()
        level = 0
        // 前回までに覚えた声の大きさから、最初から適切な増幅率で始める
        gain = Self.targetGain
        // テスト用：OILVOICE_FEED に音声ファイルを指定すると、マイクの代わりに実時間で流す
        if let feed = ProcessInfo.processInfo.environment["OILVOICE_FEED"] {
            isRunning = true
            startFeed(URL(fileURLWithPath: feed))
            return
        }
        isRunning = true
        do {
            try startEngine()
        } catch {
            isRunning = false
            throw error
        }
        DebugLog.log("recorder: recording, gain \(Int(gain))")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        feedStop = true
        if isFeed { return }
        UserDefaults.standard.set(Self.envelope, forKey: "micEnvelope")
        stopEngine()
    }

    private var feedStop = false
    private func startFeed(_ url: URL) {
        feedStop = false
        Task.detached { [weak self] in
            guard let all = try? await FileTranscriber.decode(url) else { DebugLog.log("feed: decode failed"); return }
            DebugLog.log("feed: \(all.count) samples")
            var i = 0
            while i < all.count, let self, !self.feedStop {
                let j = min(all.count, i + 1600)
                var part = Array(all[i..<j])
                part.withUnsafeMutableBufferPointer { self.applyGain($0) }
                var sum: Float = 0; for v in part { sum += v * v }
                let rms = (sum / Float(part.count)).squareRoot()
                self.level = min(1, rms * 8)
                self.peak = max(self.peak, rms)
                self.append(part)
                i = j
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func append(_ p: [Float]) {
        lock.lock(); samples.append(contentsOf: p); lock.unlock()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil || out.frameLength == 0 {
            convertFailures += 1
            if convertFailures % 50 == 1 { DebugLog.log("recorder: convert produced no frames (\(err?.localizedDescription ?? "0 frames"), in \(buffer.frameLength))") }
        }
        guard err == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        let p = UnsafeMutableBufferPointer(start: ch, count: n)
        applyGain(p)
        var sum: Float = 0
        for v in p { sum += v * v }
        let rms = (sum / Float(n)).squareRoot()
        level = min(1, rms * 8)
        peak = max(peak, rms)
        lock.lock()
        if isRunning { samples.append(contentsOf: p) }
        lock.unlock()
    }

    // MARK: - 自動ゲイン
    // Bluetooth ヘッドセットなどは音がとても小さく（-60 dB 前後）、そのままだと VAD が反応しない。
    // 直近の最大振幅を追い、話し声のピークが 0.3 前後になるように増幅する。

    /// 直近の最大振幅（ゆっくり下がる）。次の録音・次の起動にも引き継ぐ。
    private static var envelope: Float = {
        let v = UserDefaults.standard.float(forKey: "micEnvelope")
        return v > 0 ? min(v, 0.1) : 0.01
    }()
    private static var targetGain: Float { min(80, max(1, 0.3 / envelope)) }
    private(set) var gain: Float = 1

    private func applyGain(_ p: UnsafeMutableBufferPointer<Float>) {
        var m: Float = 0
        for v in p { m = max(m, abs(v)) }
        // 上がるときは即座に、下がるときはゆっくり（1 バッファ 64 ms で 6% ずつ）
        Self.envelope = max(m, Self.envelope * 0.94, 0.0005)
        let target = Self.targetGain
        // 下げるときは速く（音割れ防止）、上げるときはなめらかに
        gain += (target - gain) * (target < gain ? 0.5 : 0.2)
        let g = gain
        for i in p.indices { p[i] = max(-1, min(1, p[i] * g)) }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    /// [from, to) のコピーを取り出す
    func slice(_ from: Int, _ to: Int? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let end = min(to ?? samples.count, samples.count)
        let start = max(0, min(from, end))
        return Array(samples[start..<end])
    }
}
