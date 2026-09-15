import Foundation

public struct Match: Identifiable, Hashable, Sendable {
    public let element: UIElement
    public let score: Double
    public var id: Int { element.id }
}

/// Deterministic text matching over a snapshot. This is the v0 "brain" — a model
/// slots in behind the same interface later (query in, ranked elements out).
public enum Matcher {
    public static func rank(_ query: String, in elements: [UIElement], limit: Int = 5) -> [Match] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let qTokens = q.split(separator: " ").map(String.init)

        var scored: [Match] = []
        scored.reserveCapacity(64)
        for el in elements {
            let s = score(query: q, tokens: qTokens, element: el)
            if s > 0.3 { scored.append(Match(element: el, score: s)) }
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.element.isInteractive != b.element.isInteractive { return a.element.isInteractive }
            return area(a.element) < area(b.element)
        }

        // Collapse near-duplicates (e.g. a button and the static text inside it).
        var seen = Set<String>()
        var out: [Match] = []
        for m in scored {
            let e = m.element
            let key = "\(normalize(e.title))|\(Int(e.frame.midX / 12))|\(Int(e.frame.midY / 12))"
            if seen.insert(key).inserted {
                out.append(m)
                if out.count == limit { break }
            }
        }
        return out
    }

    // MARK: - Scoring

    static func score(query q: String, tokens qTokens: [String], element: UIElement) -> Double {
        guard element.frame.width >= 3, element.frame.height >= 3 else { return 0 }

        var best = 0.0
        for raw in element.labels {
            let l = normalize(raw)
            if l.isEmpty { continue }
            var s = 0.0
            if l == q {
                s = 1.0
            } else if l.hasPrefix(q) {
                // "To:" must not claim "To stop receiving these messages…": a prefix is only strong
                // when it covers a good share of the label.
                let coverage = Double(q.count) / Double(l.count)
                s = coverage >= 0.5 ? 0.85 : (coverage >= 0.25 ? 0.7 : 0.45 * (coverage / 0.25))
            } else if l.contains(q) {
                let coverage = Double(q.count) / Double(l.count)
                s = (0.55 + 0.25 * coverage) * min(1, coverage / 0.15)
            } else {
                let lTokens = l.split(separator: " ").map(String.init)
                let hits = qTokens.filter { qt in lTokens.contains { $0 == qt || $0.hasPrefix(qt) } }.count
                if hits > 0 { s = 0.5 * Double(hits) / Double(qTokens.count) }
                // Light typo tolerance for single-word queries.
                if s < 0.5, qTokens.count == 1, q.count >= 4 {
                    let tolerance = max(1, q.count / 4)
                    if lTokens.contains(where: { abs($0.count - q.count) <= tolerance && levenshtein(q, $0) <= tolerance }) {
                        s = max(s, 0.6)
                    }
                }
            }
            best = max(best, s)
        }
        guard best > 0 else { return 0 }
        // With thirty tabs open, some tab's title starts with almost any short label ("Sign in" vs the
        // tab "Sign in to your account"). A tab is only a match when the label is (nearly) its whole title.
        if element.isTabSwitcher, best < 0.85 { return 0 }

        let roleWeight: Double = element.isInteractive ? 1.0 : (element.role == "AXStaticText" ? 0.7 : 0.45)
        let enabledWeight = element.isEnabled ? 1.0 : 0.6
        return best * roleWeight * enabledWeight
    }

    static func area(_ e: UIElement) -> CGFloat { e.frame.width * e.frame.height }

    public static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastSpace = true
        for ch in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
