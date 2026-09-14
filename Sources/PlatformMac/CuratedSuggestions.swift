import Foundation

/// Hand-picked starting points per app. Matched by name against the live tree,
/// so anything not actually on screen is dropped.
enum CuratedSuggestions {
    static func names(for bundleID: String?) -> [String] {
        switch bundleID {
        case "com.apple.systempreferences": return ["Wi‑Fi", "Bluetooth", "General", "Displays", "Notifications", "Privacy & Security"]
        case "com.apple.finder": return ["New Folder", "Back", "Search", "View", "Share", "Tag"]
        case "com.apple.Safari": return ["Address and search field", "Share", "New Tab", "Show Sidebar", "Reload"]
        case "com.apple.mail": return ["New Message", "Reply", "Forward", "Archive", "Search"]
        case "com.apple.MobileSMS": return ["Compose", "Search", "Details"]
        case "com.apple.Notes": return ["New Note", "Search", "Share", "Checklist"]
        case "com.apple.Photos": return ["Library", "Albums", "Favorites", "Share"]
        case "com.apple.TextEdit": return ["Bold", "Italic", "Font"]
        case "com.apple.calculator": return ["=", "AC"]
        case "com.apple.iCal": return ["Today", "Week", "Month", "Add"]
        default: return []
        }
    }
}
