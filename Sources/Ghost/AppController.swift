import AppKit
import ApplicationServices
import GuideKit
import PlatformMac

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = DoubleTapDetector(modifier: .control)
    private let hud = HUDController()
    private let overlay = OverlayController()
    private lazy var walker = Walker(overlay: overlay)
    private let permissions = PermissionsWindowController()
    private var lastFrontmost: NSRunningApplication?
    private var trustPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.lastFrontmost = app }
        }

        hotkey.onTrigger = { [weak self] in self?.summon() }
        hud.onCommit = { [weak self] element, _ in
            self?.walker.cancel()
            self?.overlay.show(element)
        }
        hud.onSetupBrain = { [weak self] in self?.permissions.show() }
        hud.onBrain = { [weak self] goal, snapshot, app in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Result<BrainPlan, Error>
                do { result = .success(try await GhostBrain.plan(goal: goal, snapshot: snapshot, app: app)) }
                catch { result = .failure(error) }
                if let plan = self.hud.brainAnswered(result) {
                    self.walker.start(plan, goal: goal, app: app, snapshot: snapshot)
                }
            }
        }
        walker.replanner = { goal, done, snapshot, app in
            try await GhostBrain.plan(goal: goal, snapshot: snapshot, app: app, completed: done)
        }
        walker.onFinished = { [weak self] ok, message in
            guard let self, !ok else { return }
            // Bring the HUD back with the reason so a stall isn't silent.
            if let app = self.targetApp() {
                self.hud.show(for: app)
                self.hud.showMessage(message)
            }
        }

        if AXIsProcessTrusted() {
            hotkey.start()
        } else {
            permissions.show()
            // Global monitors only work once trusted; keep checking until they can start.
            trustPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self, AXIsProcessTrusted() else { return }
                    t.invalidate()
                    self.trustPoll = nil
                    self.hotkey.start()
                }
            }
        }
    }

    // MARK: - Summon

    @objc func summon() {
        if walker.isWalking { walker.cancel(); return }
        if overlay.isShowing { overlay.dismiss(); return }
        if hud.isShowing { hud.hide(); return }
        guard AXIsProcessTrusted() else { permissions.show(); return }
        guard let app = targetApp() else { return }
        hud.show(for: app)
    }

    private func targetApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { return front }
        return lastFrontmost
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Ghost")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let guide = NSMenuItem(title: "Show me in frontmost app", action: #selector(summon), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        menu.addItem(NSMenuItem.separator())
        let dump = NSMenuItem(title: "Copy element snapshot", action: #selector(copySnapshot), keyEquivalent: "")
        dump.target = self
        menu.addItem(dump)
        let setup = NSMenuItem(title: "Setup & Permissions…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Ghost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func showSetup() { permissions.show() }

    @objc private func copySnapshot() {
        guard AXIsProcessTrusted(), let app = targetApp() else { permissions.show(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = AXReader.describe(AXReader.snapshot(of: app))
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
