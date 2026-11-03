import AppKit
import SwiftUI

/// 入力欄の近くに出る、フォーカスを奪わないパネル
final class OverlayPanel: NSPanel {
    private let controller: DictationController
    private var hosting: NSHostingView<OverlayView>!
    private var anchorTop: CGFloat = 0
    private var anchorBelow = true
    static let width: CGFloat = 440

    init(controller: DictationController) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 140),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .aqua)
        hosting = NSHostingView(rootView: OverlayView(controller: controller, onResize: { [weak self] h in self?.resize(h) }))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 140)
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        let size = NSSize(width: Self.width, height: max(120, hosting.fittingSize.height))
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main!
        var origin: NSPoint
        // アプリによってはでたらめな座標を返すので、どこかの画面に入っているときだけ使う
        if let caret = TextInserter.caretRect(), let sc = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(caret.origin) }) {
            let vf = sc.visibleFrame
            let x = min(max(caret.minX - 24, vf.minX + 8), vf.maxX - size.width - 8)
            if caret.minY - size.height - 10 > vf.minY {
                anchorBelow = true
                anchorTop = caret.minY - 10
                origin = NSPoint(x: x, y: anchorTop - size.height)
            } else {
                anchorBelow = false
                anchorTop = caret.maxY + 10
                origin = NSPoint(x: x, y: anchorTop)
            }
        } else {
            let vf = screen.visibleFrame
            anchorBelow = false
            anchorTop = vf.minY + 120
            origin = NSPoint(x: vf.midX - size.width / 2, y: anchorTop)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        alphaValue = 0
        orderFrontRegardless()
        DebugLog.log("overlay: frame \(frame) visible \(isVisible) caret \(String(describing: TextInserter.caretRect())) screens \(NSScreen.screens.map { $0.frame })")
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; animator().alphaValue = 0 }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// 文字が増えたら高さを伸ばす（カーソル側の辺は動かさない）
    private func resize(_ height: CGFloat) {
        guard isVisible else { return }
        let h = min(max(120, height), 360)
        guard abs(frame.height - h) > 1 else { return }
        DebugLog.log("overlay: resize \(h)")
        var f = frame
        if anchorBelow { f.origin.y = anchorTop - h } else { f.origin.y = anchorTop }
        f.size.height = h
        setFrame(f, display: true, animate: false)
    }
}

struct OverlayView: View {
    @ObservedObject var controller: DictationController
    var onResize: (CGFloat) -> Void

    private var hint: AttributedString {
        switch controller.phase {
        case .finishing(let m): return AttributedString(m)
        case .error: return AttributedString("")
        default:
            if controller.willSend { return AttributedString("話し終えると送信します") }
            var a = AttributedString("最後に")
            var b = AttributedString("「送信して」")
            b.foregroundColor = Color.black.opacity(0.8)
            a += b
            a += AttributedString("と言って送信")
            return AppSettings.shared.autoSendEnabled ? a : AttributedString("Return で入力・Esc で取り消し")
        }
    }

    private var body_text: Text {
        if case .error(let m) = controller.phase {
            return Text(m).foregroundColor(Color(red: 0.75, green: 0.35, blue: 0.0))
        }
        // オイルの黄色。声が大きいほど明るく
        let dot = Text(Image(systemName: "circle.fill"))
            .foregroundColor(Color(hue: 0.13, saturation: 0.95, brightness: 0.85 + Double(controller.level) * 0.15))
            .font(.system(size: 15))
        if controller.committedText.isEmpty && controller.partialText.isEmpty {
            if case .listening = controller.phase {
                return Text("話してください  ").foregroundColor(.black.opacity(0.35)) + dot
            }
            return Text("")
        }
        var t = Text(controller.committedText).foregroundColor(.black.opacity(0.88))
        if !controller.partialText.isEmpty {
            t = t + Text(controller.committedText.isEmpty ? "" : "") + Text(controller.partialText).foregroundColor(.black.opacity(0.6))
        }
        if case .listening = controller.phase { t = t + Text("  ") + dot }
        return t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    body_text
                        .font(.system(size: 17, weight: .medium))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 26)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: HeightKey.self, value: g.size.height)
                        })
                        .id("text")
                }
                .onChange(of: controller.partialText) { _ in proxy.scrollTo("text", anchor: .bottom) }
                .onChange(of: controller.committedText) { _ in proxy.scrollTo("text", anchor: .bottom) }
            }
            HStack(spacing: 0) {
                Button(action: { controller.cancel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("取り消し（Esc）")
                Spacer()
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundColor(.black.opacity(0.45))
                    .lineLimit(1)
                Spacer()
                Button(action: { controller.confirm() }) {
                    ZStack {
                        Circle().fill(Color(red: 0.86, green: 0.2, blue: 0.2)).frame(width: 22, height: 22)
                        RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 1.6).frame(width: 9, height: 9)
                    }
                }
                .buttonStyle(.plain)
                .help("確定して入力（Return）")
                .opacity(controller.phase == .listening ? 1 : 0.4)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .padding(.top, 6)
        }
        .frame(width: OverlayPanel.width)
        .background(
            // 白のすりガラス（後ろがうっすら透ける）
            ZStack {
                FrostedGlass()
                LinearGradient(colors: [Color.white.opacity(0.72), Color.white.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onPreferenceChange(HeightKey.self) { h in onResize(h + 56) }
    }
}

/// 後ろをぼかす下地（明るい見た目で固定）
private struct FrostedGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .aqua)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
