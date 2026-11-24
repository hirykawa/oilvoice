import Foundation

/// 製品版（jp.contrea.oilvoice）と開発版（jp.contrea.oilvoice.dev）を見分ける。
/// 開発版は設定・キーチェーン・ログ・許可が製品版と別になり、同じ Mac で並べて使える。
enum AppInfo {
    static let releaseBundleID = "jp.contrea.oilvoice"
    static let bundleID = Bundle.main.bundleIdentifier ?? releaseBundleID
    static let isDev = bundleID != releaseBundleID
    static let name = isDev ? "OilVoice Dev" : "OilVoice"
}
