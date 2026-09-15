import Foundation

/// What the model hands back: either a walkable plan against the current app,
/// or plain advice when the goal isn't reachable from what's on screen.
public struct BrainPlan: Codable, Sendable {
    public struct Step: Codable, Sendable {
        /// Element id from the snapshot the model saw. Only trustworthy for the first step.
        public let elementID: Int?
        /// Label to re-find the control by once the screen has changed.
        public let target: String
        public let verb: String
        public let note: String
        /// Set when this step is "bring this app to the front" rather than a click inside the current app.
        public let app: String?
        /// True when the person has to type into this control before the next step can appear.
        public let typing: Bool?

        public var needsTyping: Bool { typing ?? false }

        enum CodingKeys: String, CodingKey { case elementID = "element_id", target, verb, note, app, typing }
    }

    public let found: Bool
    public let summary: String
    public let steps: [Step]
    public let advice: String
}

public enum BrainError: Error, LocalizedError {
    case noAPIKey
    case http(Int, String)
    case badResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .noAPIKey: return "GhostBrain needs an API key"
        case .http(let code, let msg): return "API \(code): \(msg)"
        case .badResponse(let s): return "Unexpected reply: \(s)"
        case .transport(let s): return s
        }
    }
}

/// Renders a snapshot compactly for the model. Interactive controls first, then text.
public enum SnapshotSerializer {
    public static func render(_ snap: Snapshot, limit: Int = 700) -> String {
        let interactive = snap.elements.filter { $0.isInteractive }
        let text = snap.elements.filter { !$0.isInteractive && ($0.role == "AXStaticText" || $0.role == "AXHeading") }
        let other = snap.elements.filter { !$0.isInteractive && $0.role != "AXStaticText" && $0.role != "AXHeading" }

        var lines: [String] = []
        var seen = Set<String>()
        for e in interactive + text + other {
            let key = "\(e.role)|\(Matcher.normalize(e.title))|\(Int(e.frame.midX / 8))|\(Int(e.frame.midY / 8))"
            guard seen.insert(key).inserted else { continue }
            var l = "#\(e.id) \(e.roleName)"
            if let sub = e.subrole, sub != "AXUnknown" { l += "/\(sub.dropFirst(2))" }
            l += " \"\(e.title.prefix(80))\""
            if e.labels.count > 1 { l += " alt=\"\(e.labels[1].prefix(40))\"" }
            let crumb = e.breadcrumb
            if !crumb.isEmpty { l += " in \(crumb)" }
            l += " @\(Int(e.frame.minX)),\(Int(e.frame.minY)) \(Int(e.frame.width))x\(Int(e.frame.height))"
            if !e.isEnabled { l += " disabled" }
            lines.append(l)
            if lines.count == limit { lines.append("… (\(snap.elements.count - limit) more not shown)"); break }
        }
        return lines.joined(separator: "\n")
    }
}
