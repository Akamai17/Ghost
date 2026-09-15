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
        handOffToInstalledCopy()
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Accessibility is granted to one signed copy. A second copy launched from a disk image or an old
/// build folder has a different identity and quietly loses every permission, so if the real one is
/// installed, hand off to it and quit.
@MainActor
private func handOffToInstalledCopy() {
    let here = Bundle.main.bundleURL.standardizedFileURL
    let installed = URL(fileURLWithPath: "/Applications/Ghost.app").standardizedFileURL
    guard here != installed, FileManager.default.fileExists(atPath: installed.path) else { return }
    let alert = NSAlert()
    alert.messageText = "Ghost is already installed"
    alert.informativeText = "This copy is running from \(here.deletingLastPathComponent().path). Use the one in Applications so macOS keeps its permissions."
    alert.addButton(withTitle: "Open the installed Ghost")
    alert.addButton(withTitle: "Quit")
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration())
    }
    exit(0)
}

