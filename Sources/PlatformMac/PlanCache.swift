import Foundation
import GuideKit

/// Walks that worked, kept so the same ask never costs a second GhostBrain call.
/// Keyed by the goal's words; a plan that begins by opening an app works from anywhere,
/// one that starts inside an app only counts when the person is in that app again.
public enum PlanCache {
    struct Entry: Codable {
        var goal: String
        var startBundleID: String?
        var plan: BrainPlan
        var savedAt: Date
        var uses: Int
    }

    private static let file = Keychain.dir.appendingPathComponent("plans.json")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry]? = nil

    private static let stopWords: Set<String> = [
        "help", "me", "please", "how", "do", "i", "can", "you", "to", "the", "a", "an", "my", "in", "with", "for", "of",
        "want", "wanna", "need", "show", "like", "just", "rq", "pls", "plz", "up", "it", "this", "that", "and", "so",
    ]

    public static var count: Int { all().count }

    public static func lookup(goal: String, bundleID: String?) -> BrainPlan? {
        let want = tokens(goal)
        guard !want.isEmpty else { return nil }
        let hit = all().enumerated().filter { _, e in
            let startsWithAppSwitch = e.plan.steps.first?.app.map { !$0.isEmpty } ?? false
            guard startsWithAppSwitch || e.startBundleID == bundleID else { return false }
            let have = tokens(e.goal)
            let overlap = Double(want.intersection(have).count) / Double(want.union(have).count)
            return overlap >= 0.75
        }.max { $0.element.uses < $1.element.uses }
        guard let (i, entry) = hit.map({ ($0.offset, $0.element) }) else { return nil }
        update { $0[i].uses += 1 }
        Log.write("plan cache hit \"\(entry.goal)\" (\(entry.plan.steps.count) steps, used \(entry.uses + 1)×)")
        return entry.plan
    }

    /// Store the steps a person actually clicked through, minus element ids (those were for one screen only).
    public static func remember(goal: String, bundleID: String?, summary: String, steps: [BrainPlan.Step]) {
        guard !steps.isEmpty else { return }
        let clean = steps.map { BrainPlan.Step(elementID: nil, target: $0.target, verb: $0.verb, note: $0.note, app: $0.app, typing: $0.typing) }
        let plan = BrainPlan(found: true, summary: summary, steps: clean, advice: "")
        let key = tokens(goal)
        update { list in
            list.removeAll { tokens($0.goal) == key && $0.startBundleID == bundleID }
            list.append(Entry(goal: goal, startBundleID: bundleID, plan: plan, savedAt: Date(), uses: 0))
        }
        Log.write("plan cache saved \"\(goal)\" (\(clean.count) steps)")
    }

    /// A remembered walk that failed is stale (the app changed); drop it so the next ask goes to GhostBrain.
    public static func forget(goal: String, bundleID: String?) {
        let key = tokens(goal)
        update { list in list.removeAll { tokens($0.goal) == key && ($0.startBundleID == bundleID || $0.plan.steps.first?.app != nil) } }
        Log.write("plan cache dropped \"\(goal)\"")
    }

    public static func clear() {
        update { $0.removeAll() }
    }

    // MARK: - Plumbing

    static func tokens(_ s: String) -> Set<String> {
        Set(Matcher.normalize(s).split(separator: " ").map(String.init)).subtracting(stopWords)
    }

    private static func all() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if let entries { return entries }
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = loaded
        return loaded
    }

    private static func update(_ change: (inout [Entry]) -> Void) {
        var list = all()
        lock.lock(); defer { lock.unlock() }
        change(&list)
        entries = list
        try? FileManager.default.createDirectory(at: Keychain.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: [.atomic]) }
    }
}
