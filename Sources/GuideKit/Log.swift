import Foundation

/// Append-only debug log at ~/Library/Logs/Ghost.log.
public enum Log {
    public static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Ghost.log")
    private static let queue = DispatchQueue(label: "ghost.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    public static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}
