import AppKit
import ApplicationServices

/// 前面アプリの入力欄に文字を入れる（クリップボード経由で ⌘V、終わったら元に戻す）。
enum TextInserter {
    static func insert(_ text: String, thenPressReturn: Bool) {
        let pb = NSPasteboard.general
        // 元のクリップボードを退避
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        // クリップボード履歴アプリに残さないための印
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pb.changeCount

        postKey(9, flags: .maskCommand)  // ⌘V
        if thenPressReturn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { postKey(36, flags: []) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pb.changeCount == changeCount else { return }  // その間に誰かがコピーしたら触らない
            pb.clearContents()
            let items = saved.map { d -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for (t, v) in d { it.setData(v, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticMark)
            e.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - カーソル位置

    /// 入力中のカーソル（キャレット）の画面上の位置。AppKit 座標（左下原点）で返す。
    static func caretRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
           let app = focusedApp {
            // Chrome / Electron はこれを立てないとアクセシビリティ情報を出さない
            AXUIElementSetAttributeValue(app as! AXUIElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        let element = el as! AXUIElement

        // 1) 選択範囲（キャレット）の位置
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rv = rangeValue {
            var bounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          rv, &bounds) == .success, let b = bounds {
                var r = CGRect.zero
                if AXValueGetValue(b as! AXValue, .cgRect, &r), r.width >= 0, r.height > 0, r.origin.x > 0 || r.origin.y > 0 {
                    return flip(r)
                }
            }
        }
        // 2) 入力欄そのものの枠
        var posV: CFTypeRef?, sizeV: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posV) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeV) == .success,
           let pv = posV, let sv = sizeV {
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
            if s.height > 0, s.height < 400 {
                // 入力欄の左下あたり
                return flip(CGRect(x: p.x + 8, y: p.y + s.height - 22, width: 1, height: 20))
            }
            if s.height >= 400 {
                return flip(CGRect(x: p.x + 8, y: p.y + 8, width: 1, height: 20))
            }
        }
        return nil
    }

    /// アクセシビリティの座標（主画面の左上原点）→ AppKit（左下原点）
    private static func flip(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.origin.x, y: h - r.origin.y - r.height, width: r.width, height: r.height)
    }
}
