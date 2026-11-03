import AppKit
import Combine
import Foundation

/// 起動のショートカット。「同じキーを素早く2回」か「修飾キー＋キー」のどちらか。
struct Hotkey: Codable, Equatable {
    enum Kind: String, Codable { case doubleTap, combo }
    var kind: Kind
    var keyCode: UInt16
    /// combo のときの修飾キー（CGEventFlags の rawValue のうち ⌘⌥⌃⇧fn）
    var modifiers: UInt64
    var label: String

    static let returnDoubleTap = Hotkey(kind: .doubleTap, keyCode: 36, modifiers: 0, label: "Return")
    static let spaceDoubleTap = Hotkey(kind: .doubleTap, keyCode: 49, modifiers: 0, label: "Space")
    static let `default` = spaceDoubleTap

    var display: String {
        switch kind {
        case .doubleTap: return "\(label) を2回"
        case .combo: return Hotkey.modifierSymbols(modifiers) + label
        }
    }

    static func modifierSymbols(_ raw: UInt64) -> String {
        let f = CGEventFlags(rawValue: raw)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        if f.contains(.maskSecondaryFn) { s += "fn " }
        return s
    }

    static let modifierMask: UInt64 = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskSecondaryFn.rawValue

    /// 修飾キーそのもの（右⌘など）の keyCode
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func name(forKeyCode code: UInt16, characters: String?) -> String {
        let names: [UInt16: String] = [
            36: "Return", 76: "Enter", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            54: "右⌘", 55: "左⌘", 56: "左⇧", 60: "右⇧", 58: "左⌥", 61: "右⌥", 59: "左⌃", 62: "右⌃",
            63: "fn", 57: "CapsLock",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            123: "←", 124: "→", 125: "↓", 126: "↑", 102: "英数", 104: "かな",
        ]
        if let n = names[code] { return n }
        if let c = characters, !c.isEmpty { return c.uppercased() }
        return "Key\(code)"
    }
}

/// 辞書の1項目。表記と、その読み（カンマ区切り、空なら表記のまま認識させる）
struct DictionaryEntry: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var written: String
    var readings: String
    /// 音声認識の語彙ブーストに使うか（false なら認識後の置換だけ）
    var boost: Bool = true

    var readingList: [String] {
        readings.split(whereSeparator: { $0 == "," || $0 == "、" || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case none, chatgpt, opencodeGo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "使わない"
        case .chatgpt: return "ChatGPT（サブスク枠）"
        case .opencodeGo: return "OpenCode Go"
        }
    }
}

enum ModelVariant: String, Codable, CaseIterable, Identifiable {
    case q4_k, q5_k, q6_k, q8_0
    var id: String { rawValue }
    var fileName: String {
        switch self {
        case .q4_k: return "Haas-616M-ja-v1.0-Q4_K.gguf"
        case .q5_k: return "Haas-616M-ja-v1.0-Q5_K.gguf"
        case .q6_k: return "Haas-616M-ja-v1.0-Q6_K.gguf"
        case .q8_0: return "Haas-616M-ja-v1.0-Q8_0.gguf"
        }
    }
    var size: Int64 {
        switch self {
        case .q4_k: return 351_901_216
        case .q5_k: return 428_021_280
        case .q6_k: return 508_898_848
        case .q8_0: return 656_381_472
        }
    }
    var sha256: String {
        switch self {
        case .q4_k: return "d24d53f29b75214a933ff482b0de1217e0a800f4118cca39ad6cf03609a89d6f"
        case .q5_k: return "880ee2d3068b98834d88cff5794442a7f36f1808a6b365a5f6188a060b689658"
        case .q6_k: return "19b33195b691abda293648a02702086754e1392728871d0dafcd3d50682f5dc3"
        case .q8_0: return "cd5f60b2f1c411404b83fca4a65e3ce30a26d9e951b6a346529e65f22758afeb"
        }
    }
    var label: String {
        switch self {
        case .q4_k: return "Q4_K（0.35 GB・メモリ 0.46 GiB）推奨"
        case .q5_k: return "Q5_K（0.43 GB・メモリ 0.53 GiB）"
        case .q6_k: return "Q6_K（0.51 GB・メモリ 0.61 GiB）"
        case .q8_0: return "Q8_0（0.66 GB・メモリ 0.74 GiB）"
        }
    }
}

/// UserDefaults に保存する設定。秘密情報（トークン・APIキー）は Keychain に置く。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard
    private var bag = Set<AnyCancellable>()

    @Published var hotkey: Hotkey
    @Published var doubleTapInterval: Double
    @Published var autoSendEnabled: Bool
    @Published var autoSendPhrases: String
    @Published var removeFillers: Bool
    @Published var addFinalPeriod: Bool
    @Published var dictionary: [DictionaryEntry]
    @Published var keywordsAlpha: Double
    @Published var modelVariant: ModelVariant
    @Published var aiProvider: AIProvider
    @Published var chatgptModel: String
    @Published var chatgptReasoning: String
    @Published var opencodeModel: String
    @Published var opencodeBaseURL: String
    @Published var aiPrompt: String
    @Published var aiTimeout: Double
    @Published var playSounds: Bool

    static let defaultPrompt = """
    あなたは音声入力の文字起こしを整える編集者です。入力は話し言葉をそのまま書き起こした日本語です。
    次のルールで整形し、整形後の本文だけを出力してください。説明・前置き・引用符は付けないでください。
    - 意味・語調・内容は変えない。要約しない。情報を足さない。
    - 「えー」「あのー」「えっと」などのフィラー、言い直し、重複を取り除く。
    - 句読点を整え、読みやすい自然な文章にする。必要なら改行や箇条書きを使う。
    - 明らかな誤変換・同音異義語の誤りを文脈から直す。
    - 入力が質問や依頼でも、答えずにそのまま整形した文章だけを返す。
    """

    private init() {
        // v2 から既定をスペース2回に変えた。以前の既定（Return 2回）のままなら移す
        var hk = Self.decode(Hotkey.self, d.data(forKey: "hotkey")) ?? .default
        if !d.bool(forKey: "hotkeyDefaultV2") {
            if hk == .returnDoubleTap { hk = .default }
            d.set(true, forKey: "hotkeyDefaultV2")
        }
        hotkey = hk
        doubleTapInterval = d.object(forKey: "doubleTapInterval") as? Double ?? 0.35
        autoSendEnabled = d.object(forKey: "autoSendEnabled") as? Bool ?? true
        autoSendPhrases = d.string(forKey: "autoSendPhrases") ?? "送信して,送信してください,送信します,送信"
        removeFillers = d.object(forKey: "removeFillers") as? Bool ?? true
        addFinalPeriod = d.object(forKey: "addFinalPeriod") as? Bool ?? false
        dictionary = Self.decode([DictionaryEntry].self, d.data(forKey: "dictionary")) ?? []
        keywordsAlpha = d.object(forKey: "keywordsAlpha") as? Double ?? 2.0
        modelVariant = ModelVariant(rawValue: d.string(forKey: "modelVariant") ?? "") ?? .q4_k
        aiProvider = AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .none
        chatgptModel = d.string(forKey: "chatgptModel") ?? "gpt-5.6-luna"
        chatgptReasoning = d.string(forKey: "chatgptReasoning") ?? "low"
        opencodeModel = d.string(forKey: "opencodeModel") ?? "glm-5.3-flash"
        opencodeBaseURL = d.string(forKey: "opencodeBaseURL") ?? "https://opencode.ai/inference/go/v1"
        aiPrompt = d.string(forKey: "aiPrompt") ?? Self.defaultPrompt
        aiTimeout = d.object(forKey: "aiTimeout") as? Double ?? 12
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true

        // どの値が変わっても保存する
        objectWillChange
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &bag)
    }

    func save() {
        d.set(Self.encode(hotkey), forKey: "hotkey")
        d.set(doubleTapInterval, forKey: "doubleTapInterval")
        d.set(autoSendEnabled, forKey: "autoSendEnabled")
        d.set(autoSendPhrases, forKey: "autoSendPhrases")
        d.set(removeFillers, forKey: "removeFillers")
        d.set(addFinalPeriod, forKey: "addFinalPeriod")
        d.set(Self.encode(dictionary), forKey: "dictionary")
        d.set(keywordsAlpha, forKey: "keywordsAlpha")
        d.set(modelVariant.rawValue, forKey: "modelVariant")
        d.set(aiProvider.rawValue, forKey: "aiProvider")
        d.set(chatgptModel, forKey: "chatgptModel")
        d.set(chatgptReasoning, forKey: "chatgptReasoning")
        d.set(opencodeModel, forKey: "opencodeModel")
        d.set(opencodeBaseURL, forKey: "opencodeBaseURL")
        d.set(aiPrompt, forKey: "aiPrompt")
        d.set(aiTimeout, forKey: "aiTimeout")
        d.set(playSounds, forKey: "playSounds")
    }

    /// Haas のカスタム語彙（`表記=読み,読み` を1行ずつ）
    var keywordsString: String {
        dictionary.filter { $0.boost && !$0.written.isEmpty }.map { e in
            let r = e.readingList
            return r.isEmpty ? e.written : "\(e.written)=\(r.joined(separator: ","))"
        }.joined(separator: "\n")
    }

    var autoSendPhraseList: [String] {
        autoSendPhrases.split(whereSeparator: { $0 == "," || $0 == "、" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    private static func decode<T: Decodable>(_ t: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(t, from: data)
    }

    private static func encode<T: Encodable>(_ v: T) -> Data? { try? JSONEncoder().encode(v) }
}
