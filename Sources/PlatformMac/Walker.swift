import AppKit
import GuideKit

/// Walks a plan one click at a time: point, wait for the click, re-read the tree, point at the next.
@MainActor
public final class Walker {
    public var onStatus: ((String) -> Void)?
    public var onFinished: ((Bool, String) -> Void)?
    /// Asked to produce a fresh plan from the current screen when a step's label can't be found.
    public var replanner: ((_ goal: String, _ done: [String], _ snapshot: Snapshot, _ app: NSRunningApplication) async throws -> BrainPlan)?

    private let overlay: OverlayController
    private var plan: BrainPlan?
    private var app: NSRunningApplication?
    private var index = 0
    private var firstSnapshot: Snapshot?
    private var generation = 0
    private var goal = ""
    private var completed: [String] = []
    /// Every step the person clicked through in this walk, across replans. Valid after onFinished.
    public private(set) var completedSteps: [BrainPlan.Step] = []
    private var replans = 0

    public var isWalking: Bool { plan != nil }

    public init(overlay: OverlayController) {
        self.overlay = overlay
    }

    public func start(_ plan: BrainPlan, goal: String, app: NSRunningApplication, snapshot: Snapshot) {
        cancel()
        guard !plan.steps.isEmpty else { return }
        self.plan = plan
        self.goal = goal
        self.app = app
        self.firstSnapshot = snapshot
        index = 0
        completed = []
        completedSteps = []
        replans = 0
        generation += 1
        Log.write("walk start goal=\"\(goal)\" app=\(app.localizedName ?? "?") steps=\(plan.steps.map { "\($0.verb) \"\($0.target)\"#\($0.elementID.map(String.init) ?? "-")\($0.needsTyping ? " ⌨" : "")" })")
        overlay.onResult = { [weak self] clicked in self?.stepFinished(clicked: clicked) }
        showCurrent(retries: 0)
    }

    public func cancel() {
        if plan != nil { Log.write("walk cancel at step \(index + 1)") }
        plan = nil
        generation += 1
        if overlay.isShowing { overlay.dismiss() }
    }

    /// Steps can cross apps (a menu item opens System Settings), so follow whatever is in front.
    private func currentApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { return front }
        return app
    }

    private func showCurrent(retries: Int) {
        guard let plan, let startApp = app, let app = currentApp(), index < plan.steps.count else { return }
        let step = plan.steps[index]
        let gen = generation
        let isFirst = index == 0
        let label = "\(index + 1)/\(plan.steps.count) · \(step.note)"

        // A step is an app switch only when its whole job is the app itself; models also like to
        // tag every in-app click with the app's name, and those must stay ordinary clicks.
        if let name = step.app, !name.isEmpty,
           step.target.isEmpty || step.target.caseInsensitiveCompare(name) == .orderedSame {
            bringToFront(name, step: step, label: label, gen: gen)
            return
        }
        // A freshly launched app needs longer to put its window up, and a person typing needs longer still.
        let afterTyping = index > 0 && plan.steps[index - 1].needsTyping
        let maxRetries = afterTyping ? 30 : (app.processIdentifier == startApp.processIdentifier ? 4 : 8)
        if afterTyping, retries == 0 { overlay.showToast("Type it in — Ghost is watching for “\(step.target)”") }

        DispatchQueue.global(qos: .userInitiated).async { [firstSnapshot] in
            let snap = (isFirst && retries == 0) ? (firstSnapshot ?? Sight.snapshot(of: app)) : Sight.snapshot(of: app)
            var found: UIElement?
            if isFirst, let id = step.elementID, id >= 0, id < snap.elements.count {
                found = snap.elements[id]
            }
            if found == nil, let m = Matcher.rank(step.target, in: snap.elements, limit: 1).first, m.score >= 0.5 {
                found = m.element
            }
            let best = Matcher.rank(step.target, in: snap.elements, limit: 1).first
            Log.write("step \(self.index + 1) try \(retries) app=\(snap.appName) elements=\(snap.elements.count) ocr=\(snap.elements.filter { $0.role == PixelReader.role }.count) \(Int(snap.duration * 1000))ms target=\"\(step.target)\" best=\(best.map { "\"\($0.element.title)\" \(String(format: "%.2f", $0.score))" } ?? "none") found=\(found != nil)")
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                if let found {
                    if afterTyping { self.overlay.hideToast() }
                    self.overlay.show(found, verb: step.verb, note: label)
                } else if retries < maxRetries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.showCurrent(retries: retries + 1)
                    }
                } else if let replanner = self.replanner, self.replans < 2 {
                    if afterTyping { self.overlay.hideToast() }
                    self.replans += 1
                    self.replan(with: replanner, snapshot: snap, app: app, missing: step)
                } else {
                    if afterTyping { self.overlay.hideToast() }
                    Log.write("walk fail: \"\(step.target)\" not found")
                    self.plan = nil
                    self.onFinished?(false, "Couldn't find “\(step.target)” on screen — \(step.note)")
                }
            }
        }
    }

    /// Point at the app's Dock icon; if it isn't in the Dock, open it directly and move on.
    private func bringToFront(_ name: String, step: BrainPlan.Step, label: String, gen: Int) {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me,
           (front.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame {
            Log.write("step \(index + 1) app \"\(name)\" already frontmost")
            stepFinished(clicked: true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var icon: UIElement?
            if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                let items = AXReader.snapshot(of: dock).elements.filter { $0.role == "AXDockItem" }
                icon = items.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
                    ?? Matcher.rank(name, in: items, limit: 1).first.flatMap { $0.score >= 0.8 ? $0.element : nil }
            }
            Log.write("step \(self.index + 1) app \"\(name)\" dock=\(icon?.title ?? "none")")
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                if let icon {
                    self.overlay.show(icon, verb: step.verb.isEmpty ? "Open" : step.verb, note: label)
                    return
                }
                // Not in the Dock: open it for them.
                let running = NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame }
                if let running {
                    running.activate()
                } else if let url = self.applicationURL(named: name) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    self.plan = nil
                    self.onFinished?(false, "Couldn't find an app called “\(name)”")
                    return
                }
                self.overlay.showToast("Opening \(name)…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.overlay.hideToast()
                    self.stepFinished(clicked: true)
                }
            }
        }
    }

    private func applicationURL(named name: String) -> URL? {
        let fm = FileManager.default
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", (fm.homeDirectoryForCurrentUser.path + "/Applications")] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = names.first(where: { $0.lowercased() == name.lowercased() + ".app" }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(hit)
            }
        }
        return nil
    }

    private func replan(with replanner: @escaping (String, [String], Snapshot, NSRunningApplication) async throws -> BrainPlan,
                        snapshot: Snapshot, app: NSRunningApplication, missing: BrainPlan.Step) {
        let gen = generation
        Log.write("replan #\(replans) in \(snapshot.appName), missing \"\(missing.target)\", done=\(completed)")
        overlay.showToast("Re-checking the screen…")
        Task { @MainActor [weak self] in
            do {
                let fresh = try await replanner(self?.goal ?? "", self?.completed ?? [], snapshot, app)
                guard let self, gen == self.generation else { return }
                self.overlay.hideToast()
                guard fresh.found, !fresh.steps.isEmpty else {
                    Log.write("replan: nothing to do here — \(fresh.advice.prefix(120))")
                    self.plan = nil
                    self.onFinished?(false, fresh.advice.isEmpty ? "Couldn't continue from here" : fresh.advice)
                    return
                }
                if let old = self.plan, old.steps.map(\.target) == fresh.steps.map(\.target) {
                    Log.write("replan: same plan back, stopping")
                    self.plan = nil
                    self.onFinished?(false, "Ghost can't see “\(missing.target)” in \(snapshot.appName). " + (fresh.advice.isEmpty ? "Try that step yourself, then summon Ghost again." : fresh.advice))
                    return
                }
                Log.write("replan ok steps=\(fresh.steps.map { "\($0.verb) \"\($0.target)\"" })")
                self.plan = fresh
                self.index = 0
                self.firstSnapshot = snapshot
                self.showCurrent(retries: 0)
            } catch {
                guard let self, gen == self.generation else { return }
                self.overlay.hideToast()
                Log.write("replan error: \(error.localizedDescription)")
                self.plan = nil
                self.onFinished?(false, "Couldn't find “\(missing.target)” — \(error.localizedDescription)")
            }
        }
    }

    private func stepFinished(clicked: Bool) {
        guard let plan else { return }
        Log.write("step \(index + 1) finished clicked=\(clicked)")
        guard clicked else {
            self.plan = nil
            onFinished?(false, "Stopped at step \(index + 1) of \(plan.steps.count)")
            return
        }
        completed.append(plan.steps[index].target)
        completedSteps.append(plan.steps[index])
        index += 1
        if index >= plan.steps.count {
            Log.write("walk done")
            self.plan = nil
            onFinished?(true, "Done — \(plan.summary)")
            return
        }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.showCurrent(retries: 0)
        }
    }
}
