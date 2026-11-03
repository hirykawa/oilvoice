import AppKit
import Foundation

/// 1回の音声入力（起動 → 話す → 確定して入力）を受け持つ。
final class DictationController: ObservableObject {
    enum Phase: Equatable { case idle, listening, finishing(String), error(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var committedText = ""
    @Published private(set) var partialText = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var willSend = false

    private let engine = SpeechEngine.shared
    private let settings = AppSettings.shared
    private let recorder = AudioRecorder()
    private var detector: SpeechEngine.LiveDetector?
    private var timer: Timer?
    private var busy = false
    private var finishing = false
    private var generation = 0

    // asr キューの上だけで触る
    private var pushed = 0
    private var committedParts: [String] = []
    private var committedEnd = 0
    private var lastPartialAt = 0
    private var keywords = ""
    private var alpha = 2.0

    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

    var isActive: Bool { phase != .idle }

    func setKeepMicWarm(_ on: Bool) { recorder.setKeepWarm(on) }

    // MARK: - 開始

    func start() {
        guard phase == .idle else { return }
        guard engine.isLoaded else {
            phase = .error("モデルを準備中です。メニューバーの OilVoice から状態を確認してください。")
            onShow?()
            onActiveChanged?(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.reset() }
            return
        }
        generation += 1
        committedText = ""
        partialText = ""
        willSend = false
        finishing = false
        keywords = settings.keywordsString
        alpha = settings.keywordsAlpha
        do {
            try recorder.start()
        } catch {
            phase = .error("録音を始められません: \(error.localizedDescription)")
            onShow?()
            onActiveChanged?(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.reset() }
            return
        }
        DebugLog.log("start")
        engine.queue.async { [self] in
            lastLoggedHalfSecond = -1
            pushed = 0
            committedParts = []
            committedEnd = 0
            lastPartialAt = 0
            windowText = ""
            boundaries = []
            do { detector = try SpeechEngine.LiveDetector(engine: engine) }
            catch { detector = nil; DebugLog.log("detector failed: \(error.localizedDescription)") }
        }
        phase = .listening
        onShow?()
        onActiveChanged?(true)
        if settings.playSounds { NSSound(named: "Tink")?.play() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        level = level * 0.6 + recorder.level * 0.4
        guard phase == .listening, !busy else { return }
        busy = true
        let gen = generation
        engine.queue.async { [weak self] in
            guard let self else { return }
            let (committed, partial, autoSend) = self.process(final: false)
            DispatchQueue.main.async {
                self.busy = false
                guard gen == self.generation, self.phase == .listening else { return }
                self.committedText = committed
                self.partialText = partial
                let (_, send) = TextFormatter.extractSendCommand(TextFormatter.join([committed, partial]), settings: self.settings)
                self.willSend = send
                if autoSend { self.confirm(reason: "autoSend") }  // 「送信して」で話し終えたら、そのまま送信
            }
        }
    }

    /// 話している間は「確定位置から今まで」の音声全体を毎回まとめて認識し直す（文脈が切れないように）。
    /// 長くなったら（25 秒超）、手前の無音の切れ目までを確定して、そこから先を認識し直す。asr キューの上で呼ぶ。
    /// 戻り値：（表示する全文、未使用、自動送信するか）
    private func process(final: Bool) -> (String, String, Bool) {
        guard let detector else { return ("", "", false) }
        let sr = SpeechEngine.sampleRate
        let n = recorder.count
        if n > pushed {
            let chunk = recorder.slice(pushed, n)
            chunk.withUnsafeBufferPointer { detector.push($0) }
            pushed = n
        }
        if final { detector.end() }

        // VAD は「どこで息継ぎしたか」を知るためだけに使う
        var regionEnded = false
        for (_, e) in detector.takeNewRegions() {
            let b = min(n, Int(e * Double(sr)))
            if b > committedEnd { boundaries.append(b) }
            regionEnded = true
        }
        let speaking = detector.speakingStart()
        if n / 8000 != lastLoggedHalfSecond {
            lastLoggedHalfSecond = n / 8000
            DebugLog.log(String(format: "tick: %.1fs audio, window %.1fs, peakRMS %.4f, gain %.0f, speaking %@", Double(n) / 16000, Double(n - committedEnd) / 16000, recorder.takePeak(), recorder.gain, speaking.map { String(format: "%.2f", $0) } ?? "no"))
        }

        func recognize(_ from: Int, _ to: Int) -> String {
            let audio = recorder.slice(from, to)
            guard let t = try? audio.withUnsafeBufferPointer({ try engine.transcribeOnQueue($0, keywords: keywords, alpha: alpha) }) else { return "" }
            return TextFormatter.clean(t, settings: settings)
        }

        // 窓が長くなったら、手前の切れ目までを確定
        if !final, n - committedEnd > sr * 25 {
            let cut = boundaries.last(where: { $0 - committedEnd >= sr * 5 && $0 < n - sr / 2 })
                ?? quietestPoint(from: committedEnd + sr * 10, to: n - sr)
            let c = recognize(committedEnd, cut)
            if !c.isEmpty { committedParts.append(c) }
            DebugLog.log(String(format: "commit %.1f-%.1fs: ", Double(committedEnd) / 16000, Double(cut) / 16000) + c)
            committedEnd = cut
            boundaries.removeAll { $0 <= cut }
            windowText = ""
            lastPartialAt = 0
        }

        // 確定位置から今までを丸ごと認識し直す
        let length = n - committedEnd
        if final {
            windowText = length > sr * 3 / 10 ? recognize(committedEnd, n) : ""
            DebugLog.log("final window: \(windowText)")
        } else if length > sr / 4, n - lastPartialAt >= sr / 5 || regionEnded {
            let t = recognize(committedEnd, n)
            if t != windowText { DebugLog.log("window: \(t)") }
            windowText = t
            lastPartialAt = n
        }

        let full = TextFormatter.join(committedParts + [windowText])
        // 「送信して」で言い終えて、息継ぎ（区間の終わり）が来たら自動で送信
        var autoSend = false
        if !final, regionEnded, speaking == nil, settings.autoSendEnabled {
            autoSend = TextFormatter.extractSendCommand(full, settings: settings).1
        }
        return (full, "", autoSend)
    }

    /// [from, to) の中で、いちばん静かな 0.1 秒の中心（単語の途中で切らないため）。後ろ寄りを少し優先する
    private func quietestPoint(from: Int, to: Int) -> Int {
        let audio = recorder.slice(from, to)
        let frame = 1600, hop = 320
        guard audio.count > frame else { return to }
        var best = to, bestScore = Float.greatestFiniteMagnitude
        var i = 0
        while i + frame <= audio.count {
            var e: Float = 0
            for j in i..<(i + frame) { e += audio[j] * audio[j] }
            // 後ろほど少し有利に（なるべく長く確定して、窓を短く保つ）
            let score = e * (1.2 - 0.4 * Float(i) / Float(audio.count))
            if score < bestScore { bestScore = score; best = from + i + frame / 2 }
            i += hop
        }
        return best
    }

    private var windowText = ""
    private var boundaries: [Int] = []
    private var lastLoggedHalfSecond = -1

    // MARK: - 確定・取り消し

    func confirm(reason: String = "key") {
        guard phase == .listening, !finishing else { return }
        DebugLog.log("confirm (\(reason))")
        finishing = true
        timer?.invalidate(); timer = nil
        phase = .finishing("文字にしています…")
        let gen = generation
        // 話し終わりの取りこぼしを防ぐため、ほんの少し待ってから止める
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            recorder.stop()
            engine.queue.async { [self] in
                var (text, _, _) = process(final: true)
                if text.isEmpty, recorder.count > SpeechEngine.sampleRate / 2 {
                    // VAD が拾わなかったときは全体をそのまま認識
                    let all = recorder.slice(0)
                    if let t = try? all.withUnsafeBufferPointer({ try engine.transcribeOnQueue($0, keywords: keywords, alpha: alpha) }) {
                        text = TextFormatter.clean(t, settings: settings)
                    }
                }
                detector = nil
                DispatchQueue.main.async { self.deliver(text, gen: gen) }
            }
        }
    }

    private func deliver(_ raw: String, gen: Int) {
        guard gen == generation else { return }
        let (extracted, send) = TextFormatter.extractSendCommand(raw, settings: settings)
        var text = extracted
        committedText = text
        partialText = ""
        willSend = send
        guard !text.isEmpty || send else { reset(); return }

        if AIFormatter.isAvailable(settings), !text.isEmpty {
            phase = .finishing("AI で整形しています…")
            Task { [weak self] in
                guard let self else { return }
                let source = text
                var formatted = source
                do { formatted = try await AIFormatter.formatWithTimeout(source, settings: self.settings) } catch {
                    NSLog("OilVoice AI format failed: \(error.localizedDescription)")
                }
                let out = formatted
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.insert(TextFormatter.finalize(out, settings: self.settings), send: send)
                }
            }
        } else {
            text = TextFormatter.finalize(text, settings: settings)
            insert(text, send: send)
        }
    }

    private func insert(_ text: String, send: Bool) {
        DebugLog.log("insert send=\(send): \(text)")
        reset()
        // オーバーレイが消えてから入力する
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            if text.isEmpty {
                if send { TextInserter.postKey(36, flags: []) }
            } else {
                TextInserter.insert(text, thenPressReturn: send)
            }
            History.shared.add(text)
        }
        if settings.playSounds { NSSound(named: send ? "Pop" : "Morse")?.play() }
    }

    func cancel() {
        guard phase != .idle else { return }
        DebugLog.log("cancel")
        recorder.stop()
        engine.queue.async { [self] in detector = nil }
        reset()
    }

    private func reset() {
        generation += 1
        timer?.invalidate(); timer = nil
        recorder.stop()
        busy = false
        finishing = false
        phase = .idle
        level = 0
        onHide?()
        onActiveChanged?(false)
    }
}

/// 最近の入力（メニューから再コピーできるように）
final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var items: [String] = []
    func add(_ s: String) {
        guard !s.isEmpty else { return }
        items.insert(s, at: 0)
        if items.count > 10 { items.removeLast() }
    }
}
