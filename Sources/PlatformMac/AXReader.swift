import AppKit
import ApplicationServices
import GuideKit

/// Walks an app's accessibility tree into a flat list of pointable elements.
/// AX-first is the whole strategy: when the tree is good, we get exact frames and
/// labels with no vision call. Pixels are a fallback for later.
public enum AXReader {
    public struct Limits {
        public var maxElements = 5000
        public var maxDepth = 40
        public var perCallTimeout: Float = 0.3
        public init() {}
    }

    private static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXHelpAttribute, kAXIdentifierAttribute, kAXEnabledAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXVisibleChildrenAttribute, kAXChildrenAttribute,
    ]

    public static func snapshot(of app: NSRunningApplication, limits: Limits = Limits()) -> Snapshot {
        let started = Date()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, limits.perCallTimeout)

        var out: [UIElement] = []
        var truncated = false
        var stack: [(AXUIElement, Int, [String])] = []
        for child in topLevelChildren(of: appElement).reversed() { stack.append((child, 0, [])) }

        while let (element, depth, ancestry) = stack.popLast() {
            if out.count >= limits.maxElements { truncated = true; break }
            guard let info = read(element) else { continue }

            let frame = CGRect(origin: info.position, size: info.size)

            // A closed menu is 0x0 and so are its items; an open one has real geometry. Only walk open ones.
            if info.role == "AXMenu", frame.width == 0 || frame.height == 0 { continue }
            if !Role.excluded.contains(info.role), !info.labels.isEmpty, frame.width > 0, frame.height > 0 {
                out.append(UIElement(id: out.count, role: info.role, subrole: info.subrole, labels: info.labels,
                                     frame: frame, isEnabled: info.enabled, depth: depth, ancestry: ancestry))
            }
            if depth < limits.maxDepth {
                let next = ancestry + [info.role]
                for c in info.children.reversed() { stack.append((c, depth + 1, next)) }
            }
        }

        return Snapshot(appName: app.localizedName ?? "App", pid: app.processIdentifier, elements: out,
                        capturedAt: started, truncated: truncated, duration: Date().timeIntervalSince(started))
    }

    /// Plain-text dump for debugging what the tree exposes.
    public static func describe(_ snapshot: Snapshot) -> String {
        var lines = ["# \(snapshot.appName) — \(snapshot.elements.count) elements in \(Int(snapshot.duration * 1000))ms\(snapshot.truncated ? " (truncated)" : "")"]
        for e in snapshot.elements {
            let f = e.frame
            lines.append("\(String(repeating: "  ", count: e.depth))\(e.role)\(e.subrole.map { "/\($0)" } ?? "")\t\(e.labels.joined(separator: " | "))\t[\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]\(e.isEnabled ? "" : "\tdisabled")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading one element

    private struct Info {
        var role = ""
        var subrole: String?
        var labels: [String] = []
        var enabled = true
        var position = CGPoint.zero
        var size = CGSize.zero
        var children: [AXUIElement] = []
    }

    private static func read(_ element: AXUIElement) -> Info? {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let arr = values as? [AnyObject], arr.count == attributes.count else { return nil }

        var info = Info()
        info.role = string(arr[0]) ?? ""
        guard !info.role.isEmpty else { return nil }
        info.subrole = string(arr[1])

        var labels: [String] = []
        func add(_ v: AnyObject, max: Int = 120) {
            guard let s = string(v)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= max else { return }
            if !labels.contains(s) { labels.append(s) }
        }
        add(arr[2]); add(arr[3]); add(arr[4]); add(arr[5]); add(arr[6], max: 60)
        info.labels = labels

        if let n = arr[7] as? NSNumber { info.enabled = n.boolValue }
        if let p = axValue(arr[8], .cgPoint, CGPoint.zero) { info.position = p }
        if let s = axValue(arr[9], .cgSize, CGSize.zero) { info.size = s }

        // Prefer visible children for big tables/outlines so we don't walk 10k offscreen rows.
        if let visible = elements(arr[10]), !visible.isEmpty {
            info.children = visible
        } else {
            info.children = elements(arr[11]) ?? []
        }
        return info
    }

    /// The app's windows and menu bar, minus the ordinary windows that aren't in front. A control in a
    /// window behind the focused one (a second Safari window, a minimized one) can't be clicked from
    /// where the person is, so it must never win a match. Dialogs, panels, and menus stay.
    private static func topLevelChildren(of appElement: AXUIElement) -> [AXUIElement] {
        let children = childElements(of: appElement)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) != .success || focusedRef == nil {
            AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &focusedRef)
        }
        guard let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return children }
        let focused = unsafeBitCast(ref, to: AXUIElement.self)
        return children.filter { child in
            var roleRef: CFTypeRef?, subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == "AXWindow" else { return true }
            if CFEqual(child, focused) { return true }
            AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subroleRef)
            return (subroleRef as? String) != "AXStandardWindow"
        }
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let v = value else { return [] }
        return elements(v) ?? []
    }

    // MARK: - CF plumbing

    private static func isAXValue(_ v: AnyObject) -> Bool { CFGetTypeID(v) == AXValueGetTypeID() }

    private static func string(_ v: AnyObject) -> String? {
        if isAXValue(v) { return nil }
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    private static func axValue<T>(_ v: AnyObject, _ type: AXValueType, _ zero: T) -> T? {
        guard isAXValue(v) else { return nil }
        let ax = unsafeBitCast(v, to: AXValue.self)
        guard AXValueGetType(ax) == type else { return nil }
        var out = zero
        return AXValueGetValue(ax, type, &out) ? out : nil
    }

    private static func elements(_ v: AnyObject) -> [AXUIElement]? {
        guard let arr = v as? [AnyObject] else { return nil }
        let id = AXUIElementGetTypeID()
        return arr.compactMap { CFGetTypeID($0) == id ? unsafeBitCast($0, to: AXUIElement.self) : nil }
    }
}
