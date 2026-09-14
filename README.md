# Ghost

A ghost cursor that shows you where to click. Tap ⌃ twice in any app, type what you're trying to do, press Return — a cursor floats to the control and waits for you to click it.

Two tiers:

- **Plain search** (no model, instant, offline): matches what you type against the labels in the app's accessibility tree.
- **GhostBrain** (Claude, opt-in): when search comes up empty — or you pick *Not what you're looking for? Use GhostBrain* / press ⌘↩ — it sends your goal, the visible controls, and your Mac's specs (macOS version, model, chip, displays, frontmost app + version) to `claude-opus-5` and gets back either a click-by-click plan that Ghost walks you through, or written directions when the goal can't be started from the current screen.

No voice, no vision yet.

## Build

```
./scripts/build.sh          # → dist/Ghost.app and dist/Ghost-0.1.0.dmg
```

Needs only Command Line Tools (no Xcode). Universal binary, ad-hoc signed.

## Test drive

1. Open the DMG, drag Ghost to Applications, launch it. It lives in the menu bar (cursor icon).
2. Grant Accessibility when asked (System Settings → Privacy & Security → Accessibility).
3. Open **System Settings**, tap **⌃ ⌃**, type `wifi`, press Return.
4. Try Finder (`new folder`, `view`), Safari (any link text), Mail, Messages.
5. **Copy element snapshot** in the menu dumps what the AX tree exposes for the frontmost app — paste it somewhere to see what Ghost can and can't see.

Esc dismisses. Clicking the target turns it green and clears it.

**GhostBrain:** menu bar → *Setup & Permissions…* → step 3, paste an Anthropic API key (stored in `~/Library/Application Support/Ghost/api-key`, mode 0600; `ANTHROPIC_API_KEY` in the environment also works). Then try `stop zoom opening at login` in System Settings, or something the app can't do from here — you'll get directions instead of a cursor. ⌃⌃ mid-walk cancels the walk.

## Layout

```
Sources/GuideKit      engine: element model + matcher (no AppKit)
Sources/PlatformMac   AX reader, hotkey, overlay, HUD
Sources/Ghost         app shell: menu bar, permissions, wiring
```

## Gotchas

- **Ad-hoc signing and Accessibility.** macOS ties the permission to the code signature. Every rebuild is a new signature, so after rebuilding the toggle can show "on" but stop working. Fix: System Settings → Accessibility → remove Ghost (−) and add it again. A real Developer ID cert makes this go away.
- **Not App Store-able.** Controlling other apps via the Accessibility API isn't allowed in the sandbox. Direct distribution only.
- **Electron/custom-drawn apps** may expose thin or empty trees. That's the case for the pixel fallback later.
