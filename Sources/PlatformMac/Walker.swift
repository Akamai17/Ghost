import AppKit
import GuideKit

/// Walks a plan one click at a time: point, wait for the click, re-read the tree, point at the next.
@MainActor
public final class Walker {
    public var onStatus: ((String) -> Void)?
    public var onFinished: ((Bool, String) -> Void)?

    private let overlay: OverlayController
    private var plan: BrainPlan?
    private var app: NSRunningApplication?
    private var index = 0
    private var firstSnapshot: Snapshot?
    private var generation = 0

    public var isWalking: Bool { plan != nil }

    public init(overlay: OverlayController) {
        self.overlay = overlay
    }

    public func start(_ plan: BrainPlan, app: NSRunningApplication, snapshot: Snapshot) {
        cancel()
        guard !plan.steps.isEmpty else { return }
        self.plan = plan
        self.app = app
        self.firstSnapshot = snapshot
        index = 0
        generation += 1
        overlay.onResult = { [weak self] clicked in self?.stepFinished(clicked: clicked) }
        showCurrent(retries: 0)
    }

    public func cancel() {
        plan = nil
        generation += 1
        if overlay.isShowing { overlay.dismiss() }
    }

    private func showCurrent(retries: Int) {
        guard let plan, let app, index < plan.steps.count else { return }
        let step = plan.steps[index]
        let gen = generation
        let isFirst = index == 0
        let label = "\(index + 1)/\(plan.steps.count) · \(step.note)"

        DispatchQueue.global(qos: .userInitiated).async { [firstSnapshot] in
            let snap = (isFirst && retries == 0) ? (firstSnapshot ?? AXReader.snapshot(of: app)) : AXReader.snapshot(of: app)
            var found: UIElement?
            if isFirst, let id = step.elementID, id >= 0, id < snap.elements.count {
                found = snap.elements[id]
            }
            if found == nil, let m = Matcher.rank(step.target, in: snap.elements, limit: 1).first, m.score >= 0.5 {
                found = m.element
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                if let found {
                    self.overlay.show(found, verb: step.verb, note: label)
                } else if retries < 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.showCurrent(retries: retries + 1)
                    }
                } else {
                    self.plan = nil
                    self.onFinished?(false, "Couldn't find “\(step.target)” on screen — \(step.note)")
                }
            }
        }
    }

    private func stepFinished(clicked: Bool) {
        guard let plan else { return }
        guard clicked else {
            self.plan = nil
            onFinished?(false, "Stopped at step \(index + 1) of \(plan.steps.count)")
            return
        }
        index += 1
        if index >= plan.steps.count {
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
