import Foundation

/// API key storage for the dev build. A 0600 file in Application Support — no Keychain,
/// because ad-hoc signing changes identity every rebuild and macOS prompts on each read.
/// Real users never see a key: the shipped build talks to a relay instead.
public enum Keychain {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ghost", isDirectory: true)
    static let file = dir.appendingPathComponent("api-key")
    nonisolated(unsafe) private static var cached: String??

    public static var apiKey: String? {
        get {
            if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
            if let cached { return cached }
            let v = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = (v?.isEmpty == false) ? v : nil
            cached = .some(out)
            return out
        }
        set {
            let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v, !v.isEmpty {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? Data(v.utf8).write(to: file, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                cached = .some(v)
            } else {
                try? FileManager.default.removeItem(at: file)
                cached = .some(nil)
            }
        }
    }

    public static var hasAPIKey: Bool { apiKey != nil }
}
