import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyMonitor()
    private let dictation = DictationController()
    private var overlay: OverlayPanel!
    private var settingsWindow: NSWindow?
    private var fileWindow: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var modelTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if let tab = ProcessInfo.processInfo.environment["OILVOICE_OPEN_SETTINGS"] { SettingsView.initialTab = Int(tab) ?? 0 }
        speech_log_set(nil, nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OilVoice")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay = OverlayPanel(controller: dictation)
        dictation.onShow = { [weak self] in self?.overlay.present() }
        dictation.onHide = { [weak self] in self?.overlay.dismiss() }
        dictation.onActiveChanged = { [weak self] active in
            self?.hotkeys.sessionActive = active
            self?.statusItem.button?.image = NSImage(systemSymbolName: active ? "waveform.circle.fill" : "waveform",
                                                     accessibilityDescription: "OilVoice")
        }
        hotkeys.onTrigger = { [weak self] in self?.toggle() }
        hotkeys.onConfirm = { [weak self] in self?.dictation.confirm() }
        hotkeys.onCancel = { [weak self] in self?.dictation.cancel() }

        // アクセシビリティ（キー監視・入力）とマイクの許可
        if HotkeyMonitor.hasAccessibility {
            startHotkeys()
        } else {
            HotkeyMonitor.promptAccessibility()
            openSettings()
        }
        Task { @MainActor in
            _ = await AudioRecorder.requestPermission()
            self.dictation.setKeepMicWarm(AppSettings.shared.keepMicWarm)
        }
        AppSettings.shared.$keepMicWarm.dropFirst().removeDuplicates()
            .sink { [weak self] on in self?.dictation.setKeepMicWarm(on) }
            .store(in: &bag)

        prepareModel()
        if ProcessInfo.processInfo.environment["OILVOICE_OPEN_SETTINGS"] != nil { openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        // Metal はモデルを解放せずに終わると abort するので、必ず解放する
        SpeechEngine.shared.unload()
    }

    func startHotkeys() {
        if !hotkeys.start() { NSLog("OilVoice: event tap could not be created") }
    }

    func toggle() {
        if dictation.isActive { dictation.confirm() } else { dictation.start() }
    }

    /// モデルを揃えて読み込む
    func prepareModel() {
        modelTask?.cancel()
        let variant = AppSettings.shared.modelVariant
        let mm = ModelManager.shared
        modelTask = Task.detached(priority: .userInitiated) {
            do {
                try await mm.ensure(variant)
                try SpeechEngine.shared.load(asrPath: mm.path(for: variant).path, vadPath: mm.vadPath.path)
                DebugLog.log("model loaded: \(variant.rawValue)")
                await MainActor.run {
                    mm.state = .ready; mm.objectWillChange.send()
                    if ProcessInfo.processInfo.environment["OILVOICE_AUTOSTART"] != nil { self.dictation.start() }
                }
            } catch {
                await MainActor.run { mm.state = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = AppSettings.shared
        let state: String
        switch ModelManager.shared.state {
        case .downloading(let l, let p): state = "\(l) をダウンロード中 \(Int(p * 100))%"
        case .verifying: state = "モデルを確認中…"
        case .failed(let e): state = "エラー：\(e)"
        default: state = SpeechEngine.shared.isLoaded ? "準備完了（\(s.hotkey.display)で開始）" : "モデルを読み込み中…"
        }
        let st = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        if !HotkeyMonitor.hasAccessibility {
            menu.addItem(item("⚠︎ アクセシビリティを許可する…", #selector(openSettings)))
        }
        menu.addItem(.separator())
        menu.addItem(item(dictation.isActive ? "確定して入力" : "音声入力を開始", #selector(menuToggle)))
        menu.addItem(item("音声ファイルを文字起こし…", #selector(openFileTranscription)))
        let recent = History.shared.items
        if !recent.isEmpty {
            let sub = NSMenu()
            for t in recent {
                let title = t.count > 40 ? String(t.prefix(40)) + "…" : t
                let it = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = t
                sub.addItem(it)
            }
            let h = NSMenuItem(title: "最近の入力をコピー", action: nil, keyEquivalent: "")
            h.submenu = sub
            menu.addItem(h)
        }
        menu.addItem(.separator())
        menu.addItem(item("設定…", #selector(openSettings), key: ","))
        menu.addItem(item("OilVoice を終了", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func menuToggle() {
        // メニューを閉じて元のアプリにフォーカスが戻ってから
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.toggle() }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc func openSettings() {
        settingsWindow = showWindow(settingsWindow, title: "OilVoice 設定", view: SettingsView())
    }

    @objc func openFileTranscription() {
        fileWindow = showWindow(fileWindow, title: "音声ファイルを文字起こし", view: FileTranscriptionView(), resizable: true)
    }

    private func showWindow<V: View>(_ existing: NSWindow?, title: String, view: V, resizable: Bool = false) -> NSWindow {
        if let w = existing {
            bringToFront(w)
            return w
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        // マウスのある画面の中央に出す
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = w.frame.size
            w.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        } else {
            w.center()
        }
        bringToFront(w)
        return w
    }

    /// 常駐アプリでも確実に前面に出す（macOS 14 以降は activate(ignoringOtherApps:) が効かないことがある）
    private func bringToFront(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        // 閉じたら Dock から消す
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            DispatchQueue.main.async {
                let others = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0 !== w && $0.styleMask.contains(.titled) }
                if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
