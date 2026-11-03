import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 音声・動画ファイルを読み、話している区間ごとに文字起こしする。
final class FileTranscriber: ObservableObject {
    struct Segment: Identifiable { let id = UUID(); let start: Double; let end: Double; var text: String }

    @Published var fileName = ""
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var segments: [Segment] = []
    @Published var running = false
    @Published var aiText: String?
    private var cancelled = false

    func cancel() { cancelled = true }

    func run(_ url: URL) {
        guard !running else { return }
        let settings = AppSettings.shared
        guard SpeechEngine.shared.isLoaded else { status = "モデルを準備中です。少し待ってからもう一度お試しください。"; return }
        fileName = url.lastPathComponent
        segments = []
        aiText = nil
        progress = 0
        running = true
        cancelled = false
        status = "音声を読み込んでいます…"
        let keywords = settings.keywordsString
        let alpha = settings.keywordsAlpha
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let samples = try await Self.decode(url)
                await MainActor.run { self.status = "話している区間を探しています…" }
                let found = try SpeechEngine.shared.detectRegions(samples)
                let regions = found.isEmpty && !samples.isEmpty ? [(0, Double(samples.count) / 16000)] : found
                for (i, (s, e)) in regions.enumerated() {
                    if self.cancelled { break }
                    let a = max(0, Int(s * 16000)), b = min(samples.count, Int(e * 16000))
                    guard b > a else { continue }
                    let raw = try SpeechEngine.shared.transcribe(Array(samples[a..<b]), keywords: keywords, alpha: alpha)
                    let text = TextFormatter.clean(raw, settings: settings)
                    await MainActor.run {
                        if !text.isEmpty { self.segments.append(Segment(start: s, end: e, text: text)) }
                        self.progress = Double(i + 1) / Double(regions.count)
                        self.status = "文字起こし中… \(i + 1) / \(regions.count)"
                    }
                }
                let dur = Double(samples.count) / 16000
                await MainActor.run {
                    self.running = false
                    self.progress = 1
                    self.status = self.cancelled ? "中止しました" : "完了（音声 \(Self.clock(dur, ms: false))・\(self.segments.count) 区間）"
                }
            } catch {
                await MainActor.run { self.running = false; self.status = "失敗しました: \(error.localizedDescription)" }
            }
        }
    }

    func runAI() {
        let text = plainText
        guard !text.isEmpty, AIFormatter.isAvailable(AppSettings.shared) else { return }
        status = "AI で整形しています…"
        running = true
        Task {
            do {
                let out = try await AIFormatter.format(text, settings: AppSettings.shared)
                await MainActor.run { self.aiText = out; self.running = false; self.status = "AI 整形が完了しました" }
            } catch {
                await MainActor.run { self.running = false; self.status = "AI 整形に失敗しました: \(error.localizedDescription)" }
            }
        }
    }

    /// AVAssetReader で 16 kHz モノラル float に変換（wav / mp3 / m4a / aac / flac / aiff / mp4 / mov など）
    static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SpeechEngine.Failure(message: "音声トラックがありません")
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? SpeechEngine.Failure(message: "読み込みに失敗しました") }
        return samples
    }

    // MARK: 出力

    var plainText: String { TextFormatter.join(segments.map(\.text)) }

    var timestamped: String {
        segments.map { "[\(Self.clock($0.start, ms: false))] \($0.text)" }.joined(separator: "\n")
    }

    var srt: String {
        segments.enumerated().map { i, s in
            "\(i + 1)\n\(Self.clock(s.start, ms: true, srt: true)) --> \(Self.clock(s.end, ms: true, srt: true))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

    static func clock(_ t: Double, ms: Bool, srt: Bool = false) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if ms {
            let f = Int((t - Double(total)) * 1000)
            return String(format: "%02d:%02d:%02d%@%03d", h, m, s, srt ? "," : ".", f)
        }
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

struct FileTranscriptionView: View {
    @StateObject private var t = FileTranscriber()
    @ObservedObject private var settings = AppSettings.shared
    @State private var format = 0
    @State private var targeted = false

    private var output: String {
        if let ai = t.aiText, format == 3 { return ai }
        switch format {
        case 1: return t.timestamped
        case 2: return t.srt
        default: return t.plainText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundColor(targeted ? .accentColor : .secondary.opacity(0.5))
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 26)).foregroundColor(.secondary)
                    Text(t.fileName.isEmpty ? "音声・動画ファイルをここにドロップ" : t.fileName).font(.headline)
                    Button("ファイルを選ぶ…") { choose() }.disabled(t.running)
                }
                .padding()
            }
            .frame(height: 120)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { t.run(url) } }
                }
                return true
            }

            HStack {
                if t.running { ProgressView(value: t.progress).frame(width: 160) }
                Text(t.status).font(.callout).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                if t.running { Button("中止") { t.cancel() } }
            }

            Picker("", selection: $format) {
                Text("テキスト").tag(0)
                Text("時刻付き").tag(1)
                Text("SRT 字幕").tag(2)
                if t.aiText != nil { Text("AI 整形").tag(3) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextEditor(text: .constant(output))
                .font(.system(size: 13))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

            HStack {
                Button("AI で整形") { t.runAI(); format = 3 }
                    .disabled(t.segments.isEmpty || t.running || !AIFormatter.isAvailable(settings))
                    .help(AIFormatter.isAvailable(settings) ? "" : "設定の「AI 整形」でログインまたは API キーを設定してください")
                Spacer()
                Button("コピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }.disabled(output.isEmpty)
                Button("保存…") { save() }.disabled(output.isEmpty).keyboardShortcut("s")
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 520)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { t.run(url) }
    }

    private func save() {
        let p = NSSavePanel()
        let base = (t.fileName as NSString).deletingPathExtension
        p.nameFieldStringValue = base + (format == 2 ? ".srt" : ".txt")
        p.allowedContentTypes = format == 2 ? [UTType(filenameExtension: "srt") ?? .plainText] : [.plainText]
        if p.runModal() == .OK, let url = p.url {
            try? output.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
