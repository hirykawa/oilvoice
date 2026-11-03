import Foundation

/// ~/Library/Logs/OilVoice.log に書く簡単なログ
enum DebugLog {
    private static let queue = DispatchQueue(label: "oilvoice.log")
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("OilVoice.log")
    }()
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func log(_ s: @autoclosure () -> String) {
        let line = "\(fmt.string(from: Date())) \(s())\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: url, atomically: false, encoding: .utf8)
            }
        }
    }
}
