import Foundation
import CoreGraphics

/// A UI element as observed through the accessibility tree.
/// `frame` is in AX screen space: origin at the top-left of the primary display, y grows downward.
public struct UIElement: Identifiable, Hashable, Sendable {
    public let id: Int
    public let role: String
    public let subrole: String?
    /// Candidate labels in priority order: title, description, value, help, identifier.
    public let labels: [String]
    public let frame: CGRect
    public let isEnabled: Bool
    public let depth: Int
    /// Roles of the ancestors, root first.
    public let ancestry: [String]

    public init(id: Int, role: String, subrole: String?, labels: [String], frame: CGRect,
                isEnabled: Bool, depth: Int, ancestry: [String]) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.labels = labels
        self.frame = frame
        self.isEnabled = isEnabled
        self.depth = depth
        self.ancestry = ancestry
    }

    public var title: String { labels.first ?? "" }
    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    public var isInteractive: Bool { Role.interactive.contains(role) }
    public var roleName: String { Role.humanName(for: role, subrole: subrole) }

    /// Short breadcrumb for display, e.g. "Toolbar › Group". Skips structural noise.
    public var breadcrumb: String {
        ancestry
            .filter { !Role.structural.contains($0) }
            .suffix(3)
            .map { Role.humanName(for: $0, subrole: nil) }
            .joined(separator: " › ")
    }
}

public enum Role {
    public static let interactive: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXMenuItem", "AXMenuBarItem", "AXTextField", "AXTextArea", "AXSearchField",
        "AXLink", "AXTab", "AXSlider", "AXIncrementor", "AXComboBox", "AXDisclosureTriangle",
        "AXRow", "AXCell", "AXColorWell", "AXDateField", "AXTimeField", "AXStepper", "AXSwitch",
    ]

    /// Containers that carry no meaning for a person reading a breadcrumb.
    public static let structural: Set<String> = [
        "AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXUnknown", "AXWebArea",
        "AXGenericElement", "AXList", "AXLayoutItem",
    ]

    /// Roles that are never worth pointing at on their own.
    public static let excluded: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXScrollArea", "AXSplitGroup",
        "AXSplitter", "AXLayoutArea", "AXScrollBar", "AXValueIndicator", "AXGrowArea",
        "AXUnknown", "AXWebArea", "AXToolbar", "AXMenuBar", "AXMenu",
    ]

    public static func humanName(for role: String, subrole: String?) -> String {
        if let subrole {
            switch subrole {
            case "AXToggle", "AXSwitch": return "Switch"
            case "AXCloseButton": return "Close button"
            case "AXMinimizeButton": return "Minimize button"
            case "AXZoomButton": return "Zoom button"
            case "AXTabButton": return "Tab"
            case "AXSearchField": return "Search field"
            case "AXSecureTextField": return "Password field"
            case "AXOutlineRow", "AXTableRow": return "Row"
            case "AXSortButton": return "Column header"
            default: break
            }
        }
        switch role {
        case "AXButton": return "Button"
        case "AXMenuButton", "AXPopUpButton": return "Menu button"
        case "AXCheckBox": return "Checkbox"
        case "AXRadioButton": return "Radio button"
        case "AXMenuItem": return "Menu item"
        case "AXMenuBarItem": return "Menu"
        case "AXTextField": return "Text field"
        case "AXTextArea": return "Text area"
        case "AXSearchField": return "Search field"
        case "AXLink": return "Link"
        case "AXTab": return "Tab"
        case "AXTabGroup": return "Tabs"
        case "AXSlider": return "Slider"
        case "AXIncrementor", "AXStepper": return "Stepper"
        case "AXComboBox": return "Combo box"
        case "AXDisclosureTriangle": return "Disclosure"
        case "AXRow": return "Row"
        case "AXCell": return "Cell"
        case "AXStaticText": return "Text"
        case "AXImage": return "Image"
        case "AXGroup": return "Group"
        case "AXToolbar": return "Toolbar"
        case "AXOutline": return "Outline"
        case "AXTable": return "Table"
        case "AXList": return "List"
        case "AXHeading": return "Heading"
        case "AXWindow": return "Window"
        case "AXSwitch": return "Switch"
        default: return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        }
    }
}

public struct Snapshot: Sendable {
    public let appName: String
    public let pid: Int32
    public let elements: [UIElement]
    public let capturedAt: Date
    public let truncated: Bool
    public let duration: TimeInterval

    public init(appName: String, pid: Int32, elements: [UIElement], capturedAt: Date,
                truncated: Bool, duration: TimeInterval) {
        self.appName = appName
        self.pid = pid
        self.elements = elements
        self.capturedAt = capturedAt
        self.truncated = truncated
        self.duration = duration
    }
}
