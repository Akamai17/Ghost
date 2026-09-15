import AppKit
import PlatformMac

@main
enum GhostApp {
    @MainActor
    static func main() {
        // Dev aid: `Ghost --snapshot Spotify` prints what Ghost can see in that app and exits.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[i + 1]
            guard let target = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame }) else {
                FileHandle.standardError.write("\(name) isn't running\n".data(using: .utf8)!)
                exit(1)
            }
            DispatchQueue.global().async {
                print("accessibility: \(AXIsProcessTrusted()) screen recording: \(PixelReader.hasPermission)")
                print(AXReader.describe(Sight.snapshot(of: target)))
                exit(0)
            }
            RunLoop.main.run()
        }

        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
