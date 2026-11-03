import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    static var initialTab = 0
    @State private var tab = SettingsView.initialTab

    private let tabs: [(String, String)] = [
        ("一般", "gearshape"), ("ショートカット", "keyboard"), ("辞書", "character.book.closed"),
        ("AI 整形", "sparkles"), ("モデル", "cpu"), ("ライセンス", "doc.text"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tabs.indices, id: \.self) { i in
                    Button { tab = i } label: {
                        Label(tabs[i].0, systemImage: tabs[i].1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(tab == i ? Color.accentColor.opacity(0.85) : .clear))
                            .foregroundColor(tab == i ? .white : .primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170)
            .background(Color.secondary.opacity(0.08))
            Divider()
            Group {
                switch tab {
                case 1: ShortcutTab()
                case 2: DictionaryTab().padding(16)
                case 3: AITab()
                case 4: ModelTab()
                case 5: LicenseTab().padding(8)
                default: GeneralTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 540)
    }
}

// MARK: - 一般

private struct GeneralTab: View {
    @ObservedObject var s = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var axTrusted = HotkeyMonitor.hasAccessibility

    var body: some View {
        Form {
            Section("許可") {
                HStack {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(axTrusted ? .green : .orange)
                    Text(axTrusted ? "アクセシビリティ：許可済み" : "アクセシビリティの許可が必要です（キー操作と入力に使います）")
                    Spacer()
                    if !axTrusted {
                        Button("許可する…") {
                            HotkeyMonitor.promptAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
            Section("送信") {
                Toggle("最後に「送信して」と言ったら、入力後に Return を押して送信する", isOn: $s.autoSendEnabled)
                TextField("送信の合図（カンマ区切り）", text: $s.autoSendPhrases)
                    .disabled(!s.autoSendEnabled)
            }
            Section("整形") {
                Toggle("「えー」「あのー」などのフィラーを取り除く", isOn: $s.removeFillers)
                Toggle("文末に必ず句点（。）を付ける", isOn: $s.addFinalPeriod)
            }
            Section("マイク") {
                Toggle("待機中もマイクを開いておく（話し始めを落とさない）", isOn: $s.keepMicWarm)
                Text("キーを押す直前 1 秒の音も使うので、話し始めが欠けません。音声は保存も送信もせず、録音していない間は直前 1 秒だけを持って捨て続けます。オンの間はメニューバーにマイク使用中の印が出ます。Bluetooth ヘッドセットでは音楽の音質が通話用に下がるので、気になる場合はオフにしてください。")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("その他") {
                Toggle("効果音を鳴らす", isOn: $s.playSounds)
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            let now = HotkeyMonitor.hasAccessibility
            if now != axTrusted { axTrusted = now; if now { AppDelegate.shared?.startHotkeys() } }
        }
    }
}

// MARK: - ショートカット

private struct ShortcutTab: View {
    @ObservedObject var s = AppSettings.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var kind: Hotkey.Kind = AppSettings.shared.hotkey.kind

    var body: some View {
        Form {
            Section("音声入力を始めるキー") {
                Picker("種類", selection: $kind) {
                    Text("同じキーを2回押す").tag(Hotkey.Kind.doubleTap)
                    Text("キーの組み合わせ").tag(Hotkey.Kind.combo)
                }
                .pickerStyle(.radioGroup)
                HStack {
                    Text("現在：")
                    Text(s.hotkey.display).font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                    Spacer()
                    Button(recording ? "キーを押してください…（Esc で中止）" : "変更") { recording ? stopRecording() : startRecording() }
                    Button("初期値に戻す") { s.hotkey = .default; kind = .doubleTap }
                }
                if kind == .doubleTap {
                    HStack {
                        Text("2回押しの間隔")
                        Slider(value: $s.doubleTapInterval, in: 0.2...0.6, step: 0.05)
                        Text(String(format: "%.2f 秒", s.doubleTapInterval)).monospacedDigit().frame(width: 60)
                    }
                    Text("例：Space を2回（既定）、右⌘ を2回、fn を2回。Space の場合、1回目に入った空白は起動時に自動で消します。")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("例：⌥Space、⌃⇧D、F5。組み合わせのキーは入力欄には届きません。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section("入力中のキー") {
                LabeledContent("確定して入力", value: "Return")
                LabeledContent("取り消し", value: "Esc")
                LabeledContent("確定して送信", value: "最後に「送信して」と言う")
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        HotkeyMonitor.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            let code = UInt16(e.keyCode)
            if e.type == .keyDown && code == 53 && kind == .doubleTap { stopRecording(); return nil }
            if e.type == .flagsChanged {
                // 修飾キー単体は2回押しのときだけ使える
                guard kind == .doubleTap, Hotkey.modifierKeyCodes.contains(code) else { return e }
                let pressed = e.modifierFlags.intersection([.command, .option, .control, .shift, .function, .capsLock]).isEmpty == false
                guard pressed else { return e }
                s.hotkey = Hotkey(kind: .doubleTap, keyCode: code, modifiers: 0, label: Hotkey.name(forKeyCode: code, characters: nil))
                stopRecording()
                return nil
            }
            let label = Hotkey.name(forKeyCode: code, characters: e.charactersIgnoringModifiers)
            if kind == .doubleTap {
                s.hotkey = Hotkey(kind: .doubleTap, keyCode: code, modifiers: 0, label: label)
            } else {
                let mods = UInt64(CGEventFlags(rawValue: UInt64(cgFlags(e.modifierFlags))).rawValue) & Hotkey.modifierMask
                let isFKey = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113].contains(Int(code))
                if mods == 0 && !isFKey { NSSound.beep(); return nil }  // 修飾キーなしの普通のキーは不可
                s.hotkey = Hotkey(kind: .combo, keyCode: code, modifiers: mods, label: label)
            }
            stopRecording()
            return nil
        }
    }

    private func cgFlags(_ f: NSEvent.ModifierFlags) -> UInt64 {
        var r: UInt64 = 0
        if f.contains(.command) { r |= CGEventFlags.maskCommand.rawValue }
        if f.contains(.option) { r |= CGEventFlags.maskAlternate.rawValue }
        if f.contains(.control) { r |= CGEventFlags.maskControl.rawValue }
        if f.contains(.shift) { r |= CGEventFlags.maskShift.rawValue }
        return r
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        HotkeyMonitor.paused = false
    }
}

// MARK: - 辞書

private struct DictionaryTab: View {
    @ObservedObject var s = AppSettings.shared
    @State private var written = ""
    @State private var readings = ""
    @State private var selection: DictionaryEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("固有名詞や専門用語を登録すると、認識しやすくなり、その表記で入力されます。読みはカタカナかひらがなで、複数あればカンマで区切ります（例：表記「OilVoice」読み「オイルボイス」）。")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("表記（例：Contrea）", text: $written)
                TextField("読み（例：コントレア）", text: $readings)
                Button("追加") { add() }.disabled(written.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
            Table($s.dictionary, selection: $selection) {
                TableColumn("表記") { $e in TextField("", text: $e.written) }
                TableColumn("読み") { $e in TextField("", text: $e.readings) }
                TableColumn("認識を強める") { $e in Toggle("", isOn: $e.boost).labelsHidden() }.width(90)
            }
            HStack {
                Button("選んだ語を削除") { s.dictionary.removeAll { $0.id == selection } }.disabled(selection == nil)
                Spacer()
                Text("強める度合い")
                Slider(value: $s.keywordsAlpha, in: 0.5...4, step: 0.5).frame(width: 140)
                Text(String(format: "%.1f", s.keywordsAlpha)).monospacedDigit()
            }
            Text("「認識を強める」をオフにすると、認識結果の置換（読み → 表記）だけを行います。強めすぎると、言っていない語が出やすくなります。")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func add() {
        let w = written.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        s.dictionary.append(DictionaryEntry(written: w, readings: readings.trimmingCharacters(in: .whitespaces)))
        written = ""; readings = ""
    }
}

// MARK: - AI 整形

private struct AITab: View {
    @ObservedObject var s = AppSettings.shared
    @ObservedObject var auth = ChatGPTAuth.shared
    @State private var key = AIFormatter.opencodeKey ?? ""
    @State private var testInput = "えーと、明日の会議なんですけど、あのー、10時からに変更でお願いします"
    @State private var testOutput = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Picker("使うサービス", selection: $s.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                Text("確定したときに、文字起こしを AI で読みやすく整えてから入力します。音声はクラウドに送らず、文字だけを送ります。")
                    .font(.caption).foregroundColor(.secondary)
            }
            if s.aiProvider == .chatgpt {
                Section("ChatGPT") {
                    HStack {
                        if let t = auth.tokens {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("ログイン中\(t.email.map { "：\($0)" } ?? "")")
                            Spacer()
                            Button("ログアウト") { auth.logout() }
                        } else {
                            Text("ChatGPT アカウントでログインすると、Plus / Pro などのサブスク枠で整形できます。")
                            Spacer()
                            Button("ChatGPT でログイン") { auth.login() }
                        }
                    }
                    if !auth.status.isEmpty { Text(auth.status).font(.caption).foregroundColor(.secondary) }
                    ModelField(title: "モデル", value: $s.chatgptModel, options: AIFormatter.chatgptModels)
                    Picker("推論の強さ", selection: $s.chatgptReasoning) {
                        Text("指定しない").tag("")
                        Text("minimal").tag("minimal")
                        Text("low（速い）").tag("low")
                        Text("medium").tag("medium")
                    }
                }
            }
            if s.aiProvider == .opencodeGo {
                Section("OpenCode Go") {
                    SecureField("API キー", text: $key)
                        .onChange(of: key) { v in AIFormatter.opencodeKey = v.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ModelField(title: "モデル", value: $s.opencodeModel, options: AIFormatter.opencodeModels)
                    TextField("エンドポイント", text: $s.opencodeBaseURL)
                    Link("OpenCode Go の API キーを取得", destination: URL(string: "https://opencode.ai/auth")!).font(.caption)
                }
            }
            if s.aiProvider != .none {
                Section("指示") {
                    TextEditor(text: $s.aiPrompt).font(.system(size: 12)).frame(height: 110)
                    HStack {
                        Button("初期値に戻す") { s.aiPrompt = AppSettings.defaultPrompt }
                        Spacer()
                        Text("タイムアウト")
                        Stepper(String(format: "%.0f 秒", s.aiTimeout), value: $s.aiTimeout, in: 3...60, step: 1)
                    }
                }
                Section("試す") {
                    TextField("入力", text: $testInput)
                    HStack {
                        Button(testing ? "整形中…" : "整形してみる") { test() }.disabled(testing || !AIFormatter.isAvailable(s))
                        Text(testOutput).textSelection(.enabled).font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        testing = true
        testOutput = ""
        Task {
            do { let r = try await AIFormatter.format(testInput, settings: s); await MainActor.run { testOutput = r } }
            catch { await MainActor.run { testOutput = "失敗：\(error.localizedDescription)" } }
            await MainActor.run { testing = false }
        }
    }
}

private struct ModelField: View {
    let title: String
    @Binding var value: String
    let options: [String]
    var body: some View {
        HStack {
            TextField(title, text: $value)
            Menu("選ぶ") { ForEach(options, id: \.self) { o in Button(o) { value = o } } }.fixedSize()
        }
    }
}

// MARK: - モデル

private struct ModelTab: View {
    @ObservedObject var s = AppSettings.shared
    @ObservedObject var m = ModelManager.shared

    var body: some View {
        Form {
            Section("音声認識モデル：Haas-ja-v1.0（Third Intelligence、Apache-2.0）") {
                Picker("量子化", selection: $s.modelVariant) {
                    ForEach(ModelVariant.allCases) { v in
                        Text(v.label + (m.isInstalled(v) ? "  ✓" : "")).tag(v)
                    }
                }
                .onChange(of: s.modelVariant) { _ in AppDelegate.shared?.prepareModel() }
                Text("精度はどれもほぼ同じ（FLEURS 日本語の CER 4.4% 前後）で、速さも変わりません。小さいほどメモリが少なくて済みます。")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    statusView
                    Spacer()
                    Button("Finder で開く") { NSWorkspace.shared.open(m.directory) }
                }
                ForEach(ModelVariant.allCases.filter { m.isInstalled($0) && $0 != s.modelVariant }) { v in
                    HStack {
                        Text(v.fileName).font(.caption)
                        Spacer()
                        Button("削除") { m.delete(v) }
                    }
                }
            }
            Section("動作") {
                LabeledContent("実行エンジン", value: "speech.cpp \(String(cString: speech_version())) ・ Metal（GPU）")
                LabeledContent("音声区間検出", value: "Silero VAD v6.2（MIT）")
                LabeledContent("処理", value: "すべて Mac の中で処理します（AI 整形を除く）")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusView: some View {
        switch m.state {
        case .idle: Text("待機中").foregroundColor(.secondary)
        case .downloading(let l, let p):
            HStack { Text("\(l) をダウンロード中"); ProgressView(value: p).frame(width: 140); Text("\(Int(p * 100))%").monospacedDigit() }
        case .verifying(let l): Text("\(l) を確認中…")
        case .ready: Label(SpeechEngine.shared.isLoaded ? "読み込み済み" : "準備できました", systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .failed(let e):
            HStack { Text("失敗：\(e)").foregroundColor(.red); Button("再試行") { AppDelegate.shared?.prepareModel() } }
        }
    }
}

// MARK: - ライセンス

private struct LicenseTab: View {
    private var text: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              var s = try? String(contentsOf: url, encoding: .utf8) else { return "THIRD_PARTY_NOTICES.md が見つかりません" }
        if let dir = Bundle.main.url(forResource: "Licenses", withExtension: nil),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let body = try? String(contentsOf: f, encoding: .utf8) {
                    s += "\n\n────────────────────────\n\(f.lastPathComponent)\n────────────────────────\n\n\(body)"
                }
            }
        }
        return s
    }

    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
