import AppKit
import Foundation

/// The machine facts the model needs to give macOS-specific directions.
public enum SystemInfo {
    public static func describe(app: NSRunningApplication?) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = []
        lines.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(marketingName(os.majorVersion)))")
        lines.append("Mac: \(sysctl("hw.model") ?? "unknown") · \(chip()) · \(Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)) GB")
        let screens = NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x" }
        lines.append("Displays: \(screens.joined(separator: ", "))")
        lines.append("Appearance: \(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light")")
        lines.append("Language: \(Locale.preferredLanguages.first ?? "en")")
        if let app {
            var a = "Frontmost app: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))"
            if let url = app.bundleURL, let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String { a += " v\(v)" }
            if let url = app.bundleURL, FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
                a += " [Electron]"
            }
            lines.append(a)
        }
        return lines.joined(separator: "\n")
    }

    static func marketingName(_ major: Int) -> String {
        switch major {
        case 14: return "Sonoma"
        case 15: return "Sequoia"
        case 26: return "Tahoe"
        default: return "macOS \(major)"
        }
    }

    static func chip() -> String {
        if let brand = sysctl("machdep.cpu.brand_string") { return brand }
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
