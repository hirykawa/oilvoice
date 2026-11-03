import AppKit
import ApplicationServices

/// キーボード全体を見て、起動ショートカットと入力中の Return / Esc を拾う。
/// アクセシビリティの許可が要る。
final class HotkeyMonitor {
    /// 自分で送ったキーに付ける印（これが付いたイベントは無視する）
    static let syntheticMark: Int64 = 0x0115_7015
    /// 設定画面でキーを登録している間は止める
    static var paused = false

    var onTrigger: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 入力中（オーバーレイ表示中）か
    var sessionActive = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastTapTime: TimeInterval = 0
    private var lastTapCode: UInt16 = .max
    private var modifierDown = false
    private var swallowKeyUp = Set<UInt16>()
    private let settings = AppSettings.shared

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
                                            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                                            return me.handle(type, event)
                                        }, userInfo: refcon) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    private func fire(_ f: (() -> Void)?) { DispatchQueue.main.async { f?() } }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if Self.paused || event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMark {
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.rawValue & Hotkey.modifierMask
        let hk = settings.hotkey
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .keyUp:
            if swallowKeyUp.remove(code) != nil { return nil }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // 修飾キーの2回押し（右⌘ を2回、など）
            guard hk.kind == .doubleTap, Hotkey.modifierKeyCodes.contains(hk.keyCode) else { return Unmanaged.passUnretained(event) }
            if code == hk.keyCode {
                modifierDown.toggle()
                if modifierDown { registerTap(code, now) }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let plain = (mods & ~CGEventFlags.maskSecondaryFn.rawValue) == 0

            if sessionActive {
                if (code == 36 || code == 76) && plain {
                    DebugLog.log("hotkey: Return during session")
                    swallowKeyUp.insert(code)
                    if !isRepeat { fire(onConfirm) }
                    return nil
                }
                if code == 53 {
                    swallowKeyUp.insert(code)
                    if !isRepeat { fire(onCancel) }
                    return nil
                }
                if hk.kind == .combo, code == hk.keyCode, mods == hk.modifiers {
                    swallowKeyUp.insert(code)
                    if !isRepeat { fire(onConfirm) }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

            switch hk.kind {
            case .combo:
                if code == hk.keyCode, mods == hk.modifiers {
                    swallowKeyUp.insert(code)
                    if !isRepeat { fire(onTrigger) }
                    return nil
                }
            case .doubleTap:
                if Hotkey.modifierKeyCodes.contains(hk.keyCode) {
                    lastTapCode = .max  // 修飾キーの2回押しの間に別のキーが入ったら取り消す
                } else if code == hk.keyCode, plain, !isRepeat {
                    if registerTap(code, now, fireNow: false) {
                        // 2回目は入力欄に渡さない（1回目はそのまま渡っている）
                        swallowKeyUp.insert(code)
                        // Space の1回目で入った空白を消す
                        if code == 49 { TextInserter.postKey(51, flags: []) }
                        fire(onTrigger)
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                } else {
                    lastTapCode = .max
                }
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 2回押しを数える。2回目なら true（fireNow なら起動も呼ぶ）
    @discardableResult
    private func registerTap(_ code: UInt16, _ now: TimeInterval, fireNow: Bool = true) -> Bool {
        if code == lastTapCode, now - lastTapTime <= settings.doubleTapInterval {
            lastTapCode = .max
            if fireNow {
                fire(sessionActive ? onConfirm : onTrigger)
            }
            return true
        }
        lastTapCode = code
        lastTapTime = now
        return false
    }
}
