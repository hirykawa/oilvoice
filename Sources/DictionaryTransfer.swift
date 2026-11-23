import AppKit
import UniformTypeIdentifiers

/// 辞書を JSON で書き出し・読み込みする。Claude や ChatGPT に編集してもらうためのもの。
enum DictionaryTransfer {
    /// 書き出す形。id は持たず、boost は省略可（省略時 true）。
    private struct Item: Codable {
        var written: String
        var readings: String?
        var boost: Bool?
    }

    static func json(_ dict: [DictionaryEntry]) -> String {
        let items = dict.map { Item(written: $0.written, readings: $0.readings, boost: $0.boost) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return String(data: (try? enc.encode(items)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    /// AI の返答から辞書を取り出す。コードブロックや前後の説明文があっても、最初の [ から最後の ] までを読む。
    static func parse(_ text: String) -> [DictionaryEntry]? {
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b,
              let items = try? JSONDecoder().decode([Item].self, from: Data(text[a...b].utf8))
        else { return nil }
        return items.compactMap { i in
            let w = i.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { return nil }
            return DictionaryEntry(written: w, readings: (i.readings ?? "").trimmingCharacters(in: .whitespaces), boost: i.boost ?? true)
        }
    }

    /// Claude / ChatGPT に貼る指示文（今の辞書つき）
    static func prompt(_ dict: [DictionaryEntry]) -> String {
        """
        音声入力アプリ OilVoice の辞書を編集してください。辞書は次の形式の JSON 配列です。

        - written: 入力したい表記（例: "Contrea"）
        - readings: 話したときの読み。カタカナで書き、複数あればカンマで区切る（例: "コントレア"）。表記どおりに読むなら空でよい
        - boost: 音声認識でこの語を聞き取りやすくするなら true。固有名詞や専門用語は true、認識後の置き換えだけでよければ false

        返答のしかた:
        - 編集後の辞書全体を、JSON 配列だけで返してください（説明は不要です）
        - 頼んでいない既存の項目は、そのまま残してください

        今の辞書:
        \(json(dict))

        頼みたいこと:

        """
    }

    static func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func save(_ dict: [DictionaryEntry]) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "oilvoice-dictionary.json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? json(dict).write(to: url, atomically: true, encoding: .utf8)
    }

    static func openFile() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json, .plainText]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 表記が同じ項目は上書きし、ない項目は足す
    static func merge(_ base: [DictionaryEntry], _ add: [DictionaryEntry]) -> [DictionaryEntry] {
        var out = base
        for e in add {
            if let i = out.firstIndex(where: { $0.written == e.written }) {
                out[i].readings = e.readings
                out[i].boost = e.boost
            } else {
                out.append(e)
            }
        }
        return out
    }
}
