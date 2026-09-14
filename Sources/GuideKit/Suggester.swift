import Foundation

/// Picks a handful of controls worth surfacing before the user types anything.
/// Curated names for the app win; the rest is filled from the tree by prominence.
public enum Suggester {
    public static func pick(from elements: [UIElement], preferred: [String] = [], limit: Int = 6) -> [UIElement] {
        var out: [UIElement] = []
        var seen = Set<String>()

        for name in preferred {
            if let m = Matcher.rank(name, in: elements, limit: 1).first, m.score >= 0.8,
               seen.insert(Matcher.normalize(m.element.title)).inserted {
                out.append(m.element)
                if out.count == limit { return out }
            }
        }

        let candidates = elements
            .filter { e in
                e.isInteractive && e.isEnabled && e.role != "AXRow" && e.role != "AXCell"
                    && e.role != "AXMenuBarItem" && e.role != "AXMenuItem"
                    && (2...28).contains(e.title.count)
                    && e.title.rangeOfCharacter(from: .letters) != nil
                    && e.frame.width >= 12 && e.frame.height >= 12
            }
            .sorted { prominence($0) > prominence($1) }

        for e in candidates {
            if seen.insert(Matcher.normalize(e.title)).inserted {
                out.append(e)
                if out.count == limit { break }
            }
        }
        return out
    }

    /// Shallow, toolbar-ish, big-ish controls first.
    static func prominence(_ e: UIElement) -> Double {
        var s = 0.0
        s -= Double(e.depth) * 0.6
        if e.ancestry.contains("AXToolbar") { s += 6 }
        if e.ancestry.contains("AXTabGroup") || e.role == "AXTab" { s += 5 }
        if e.role == "AXButton" || e.role == "AXPopUpButton" { s += 2 }
        if e.ancestry.contains("AXOutline") || e.ancestry.contains("AXTable") { s -= 3 }
        s += min(4, Double(e.frame.width * e.frame.height) / 6000)
        return s
    }
}
