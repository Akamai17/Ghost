import Foundation

/// What a regular of each app knows that a screenshot can't say: which icon-only buttons do what,
/// where the short paths are. Fed to GhostBrain so it plans the way a person who uses the app would.
enum AppHints {
    static func text(for bundleID: String?) -> String? {
        switch bundleID {
        case "com.spotify.client": return """
            Left sidebar is "Your Library"; the "+" button beside that heading opens a menu: Playlist, Blend, Folder. \
            Creating a Blend: click "+" → "Blend" → it makes the Blend and shows "Invite" → choose how to share the link (Messages, Copy link). \
            Creating a playlist: "+" → "Playlist". Search is the box "What do you want to play?" at the top; type, then press Return. \
            "..." buttons are More options menus. The Blend/playlist page has a green play button and "Add" for songs. \
            Ghost sees this app by reading text off the screen, so icon-only buttons appear as symbols like "+", "...", "<", ">".
            """
        case "com.tinyspeck.slackmacgap": return """
            The "+" in the sidebar next to "Channels" or "Direct messages" creates one. Search is the bar at the top of the window. \
            Preferences live under the workspace name menu (top left) → Preferences.
            """
        case "com.hnc.Discord": return """
            Servers are the icon column on the far left; the "+" at its bottom adds a server. Channels for the selected server are the next column. \
            User Settings is the gear beside the username at the bottom left.
            """
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser": return """
            The three-dot "⋮" button at the top right is the main menu (Settings, History, Bookmarks, Extensions). \
            Settings can also be reached by typing chrome://settings in the address bar.
            """
        case "com.microsoft.VSCode": return """
            The gear at the bottom left opens Settings, Keyboard Shortcuts, and Extensions. The activity bar icons on the far left: Explorer, Search, Source Control, Run, Extensions. \
            Almost everything is reachable from the Command Palette: ⌘⇧P.
            """
        case "notion.id": return """
            "+ New page" is at the bottom of the sidebar. Settings & members is in the sidebar under the workspace name. \
            The "..." at the top right of a page has Export, Delete, Move to.
            """
        default: return nil
        }
    }
}
