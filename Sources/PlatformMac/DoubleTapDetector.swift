import AppKit

/// Fires when a modifier key is tapped twice in quick succession with nothing else pressed.
/// Global monitors only deliver key events once the app is trusted for Accessibility,
/// so `start()` is called by the app once that's true.
@MainActor
public final class DoubleTapDetector {
    public var onTrigger: (() -> Void)?

    private let modifier: NSEvent.ModifierFlags
    private let window: TimeInterval = 0.35
    private var monitors: [Any] = []
    private var isDown = false
    private var pressedAt: TimeInterval = 0
    private var lastTapAt: TimeInterval = -1
    private var tainted = false

    public init(modifier: NSEvent.ModifierFlags = .option) {
        self.modifier = modifier
    }

    public var isRunning: Bool { !monitors.isEmpty }

    public func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(m)
        }
    }

    public func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            // Any key or click between taps means it was a shortcut, not a summon.
            tainted = true
            lastTapAt = -1
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let now = event.timestamp

        if flags == modifier, !isDown {
            isDown = true
            pressedAt = now
            tainted = false
            if lastTapAt >= 0, now - lastTapAt < window {
                lastTapAt = -1
                onTrigger?()
            }
        } else if !flags.contains(modifier), isDown {
            isDown = false
            let clean = !tainted && (now - pressedAt) < 0.3
            lastTapAt = clean ? now : -1
        } else if flags != modifier, !flags.isEmpty {
            tainted = true
        }
    }
}
