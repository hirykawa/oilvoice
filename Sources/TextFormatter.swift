import Foundation

/// 認識結果をその場で整える（ローカル・即時）。AI 整形はこの後に任意でかける。
enum TextFormatter {
    private static let fillerPattern: NSRegularExpression = {
        // 単独で現れるフィラー（直後の読点ごと消す）
        let fillers = ["えーっと", "えーと", "えっと", "えー+", "ええと", "あのー+", "あの〜", "あー+", "うーん", "うー+", "んー+", "そのー+", "まー+"]
        let p = "(?:(?<=^)|(?<=[。、！？\\s]))(?:" + fillers.joined(separator: "|") + ")[、,]?\\s*"
        return try! NSRegularExpression(pattern: p)
    }()

    /// 1区間の認識結果を整える
    static func clean(_ raw: String, settings s: AppSettings) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return t }
        if s.removeFillers {
            t = fillerPattern.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        t = applyDictionary(t, s.dictionary)
        // 重なった句読点をまとめる
        t = t.replacingOccurrences(of: "、+", with: "、", options: .regularExpression)
        t = t.replacingOccurrences(of: "。+", with: "。", options: .regularExpression)
        t = t.replacingOccurrences(of: "^[、。]+", with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 読み → 表記の置換（認識側の語彙ブーストで拾えなかった分の保険）
    static func applyDictionary(_ text: String, _ dict: [DictionaryEntry]) -> String {
        var t = text
        for e in dict where !e.written.isEmpty {
            for r in e.readingList where r != e.written {
                t = t.replacingOccurrences(of: r, with: e.written, options: [.caseInsensitive, .widthInsensitive])
            }
        }
        return t
    }

    /// 区間ごとのテキストをつなぐ
    static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if let last = out.last, !"。、！？!?\n」』）)".contains(last) {
                // 日本語の文の切れ目には句点を補う（英数字同士はスペース）
                if last.isASCII && last.isLetter && p.first?.isASCII == true { out += " " } else { out += "。" }
            }
            out += p
        }
        return out
    }

    /// 末尾の「送信して」を取り除き、送信するかどうかを返す
    static func extractSendCommand(_ text: String, settings s: AppSettings) -> (String, Bool) {
        guard s.autoSendEnabled else { return (text, false) }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " 　\n。、．.！!？?"))
        for phrase in s.autoSendPhraseList {
            if trimmed.hasSuffix(phrase) {
                var rest = String(trimmed.dropLast(phrase.count))
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " 　\n、,"))
                return (rest, true)
            }
        }
        return (text, false)
    }

    static func finalize(_ text: String, settings s: AppSettings) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.addFinalPeriod {
            // 1文だけのときは末尾の句点を付けない（チャット向け）。複数文なら残す。
            let sentences = t.components(separatedBy: "。").filter { !$0.isEmpty }
            if sentences.count <= 1, t.hasSuffix("。") { t.removeLast() }
        } else if let last = t.last, !"。！？!?".contains(last) {
            t += "。"
        }
        return t
    }
}
