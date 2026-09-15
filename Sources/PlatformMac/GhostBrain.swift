import AppKit
import Foundation
import GuideKit

/// Calls Claude with the machine specs + the live element snapshot, gets a plan back.
/// Raw HTTP: there's no official Swift SDK.
public enum GhostBrain {
    public static let model = "claude-opus-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let systemPrompt = """
    You are GhostBrain, the planner inside Ghost, a macOS helper that shows people where to click by moving a ghost cursor over the screen. \
    You receive the user's goal, facts about their Mac, and a numbered list of the controls currently visible in the frontmost app (from the accessibility tree; \
    coordinates are in points, origin top-left). Ghost cannot type, scroll, or open apps for the user — it can only point at one control at a time and wait for them to click it. \
    Controls listed as \"Text on screen\" were read off the pixels because the app hides its controls from the accessibility tree; \
    each one is the label of whatever sits there (a sidebar item, button, tab), so point at it like any control. In such apps the list is only text, \
    so plan clicks on the words a person would click, and give element_id for the first step as usual.

    Decide whether the goal can be started from what is on screen right now.

    If it can, set found=true and return the steps as a sequence of single clicks. For the first step, give the element_id of the control from the list. \
    For later steps the screen will have changed, so give element_id=null and a target label that will appear on the control (match the exact wording macOS uses on this version). \
    If the goal is about an app that is not frontmost, make the first step bring it to the front: set app to the app's name, target to the same name, verb "Open", element_id null. \
    Ghost points at its Dock icon (or opens it if it isn't in the Dock). The app field is ONLY for that kind of step — every click inside an app has app=null. \
    Later steps happen inside that app; you haven't seen its screen, so use the labels that app normally shows. \
    If the person must type into the control you're pointing at (a search box, a name field), set typing=true on that step and put what to type, and whether to press Return, \
    in its note. Never add a second step for the same field. Ghost then waits for them to type and looks for the next step's target, so that target must be something \
    that appears only after typing (a result, a heading, a button). \
    Steps may cross apps: if a click opens another app (for example a menu item that opens System Settings), keep going with steps inside that app. \
    Keep steps to what a person needs; a step's note is one short sentence explaining why, in plain language for someone who isn't technical. Verbs are short: Click, Open, Toggle, Choose, Select.

    If the goal can't be started here (wrong app, needs a different window), set found=false, steps=[], and put a short numbered set of directions in advice \
    that are specific to this macOS version and this Mac. Never invent controls that are not in the list for the first step. \
    When you are re-planning mid-task and the next thing isn't visible yet, assume the page hasn't loaded or the person hasn't typed yet: plan from what is on screen \
    (pointing at the field again with typing=true is fine). Only say a feature doesn't exist when the screen shows that; never from memory of an app version.

    summary is one line describing what you're about to walk them through.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "found": ["type": "boolean"],
            "summary": ["type": "string"],
            "steps": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "element_id": ["type": ["integer", "null"]],
                        "target": ["type": "string"],
                        "verb": ["type": "string"],
                        "note": ["type": "string"],
                        "app": ["type": ["string", "null"]],
                        "typing": ["type": "boolean"],
                    ],
                    "required": ["element_id", "target", "verb", "note", "app", "typing"],
                    "additionalProperties": false,
                ],
            ],
            "advice": ["type": "string"],
        ],
        "required": ["found", "summary", "steps", "advice"],
        "additionalProperties": false,
    ]

    public static func plan(goal: String, snapshot: Snapshot, app: NSRunningApplication?, completed: [String] = []) async throws -> BrainPlan {
        guard let key = Keychain.apiKey else { throw BrainError.noAPIKey }

        let progress = completed.isEmpty ? "" : "\nALREADY DONE (the user clicked these, in order): \(completed.joined(separator: " → ")). Plan only what remains, starting from what is on screen now.\n"
        let userText = """
        GOAL: \(goal)
        \(progress)
        MACHINE:
        \(await MainActor.run { SystemInfo.describe(app: app) })

        \(AppHints.text(for: app?.bundleIdentifier).map { "HOW \(snapshot.appName) WORKS (from someone who uses it daily — prefer these paths):\n\($0)\n" } ?? "")
        RUNNING APPS: \(await MainActor.run { SystemInfo.runningApps() }.joined(separator: ", "))
        IN THE DOCK: \(await MainActor.run { SystemInfo.dockApps() }.joined(separator: ", "))

        VISIBLE CONTROLS in \(snapshot.appName) (\(snapshot.elements.count) total\(snapshot.truncated ? ", list truncated" : "")):
        \(SnapshotSerializer.render(snapshot))
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "fallbacks": "default",
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "system": [["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": userText]],
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw BrainError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw BrainError.badResponse("no HTTP response") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrainError.badResponse(String(data: data, encoding: .utf8)?.prefix(200).description ?? "non-JSON")
        }
        guard http.statusCode == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "request failed"
            throw BrainError.http(http.statusCode, msg)
        }
        if let stop = json["stop_reason"] as? String, stop == "refusal" {
            throw BrainError.badResponse("the model declined this request")
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let textData = text.data(using: .utf8) else {
            throw BrainError.badResponse("no text block")
        }
        do {
            return try JSONDecoder().decode(BrainPlan.self, from: textData)
        } catch {
            throw BrainError.badResponse(String(text.prefix(200)))
        }
    }
}
