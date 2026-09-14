import AppKit
import QuartzCore
import GuideKit

/// A click-through window over the whole screen that hosts the ghost cursor,
/// the target highlight, and a one-line label. Never moves the real cursor.
@MainActor
public final class OverlayController {
    /// The one accent color, reserved for guidance and nothing else.
    public static let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)

    public private(set) var isShowing = false
    public var onDismiss: (() -> Void)?
    /// true when the user clicked the target; false on esc/timeout/stray clicks.
    public var onResult: ((Bool) -> Void)?
    private var succeeded = false

    private var window: OverlayWindow?
    private var monitors: [Any] = []
    private var target = CGRect.zero          // AppKit screen coords
    private var timeout: DispatchWorkItem?
    private var strayClicks = 0

    public init() {}

    public func show(_ element: UIElement, verb: String = "Click", note: String? = nil) {
        dismiss(animated: false)
        succeeded = false

        let targetAppKit = ScreenSpace.toAppKit(element.frame)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(targetAppKit) }) ?? NSScreen.main else { return }
        target = targetAppKit

        let window = OverlayWindow(screen: screen)
        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        self.window = window

        let origin = screen.frame.origin
        let mouse = NSEvent.mouseLocation
        let start = CGPoint(x: mouse.x - origin.x, y: mouse.y - origin.y)
        let local = targetAppKit.offsetBy(dx: -origin.x, dy: -origin.y)

        window.alphaValue = 1
        window.orderFrontRegardless()
        view.present(cursorFrom: start, to: CGPoint(x: local.midX, y: local.midY), highlighting: local, verb: verb, title: element.title, note: note)
        isShowing = true
        strayClicks = 0
        installMonitors()

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    public func dismiss(animated: Bool = true) {
        timeout?.cancel()
        timeout = nil
        removeMonitors()
        guard let window else { return }
        self.window = nil
        let wasShowing = isShowing
        isShowing = false
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                window.animator().alphaValue = 0
            }, completionHandler: { window.orderOut(nil) })
        } else {
            window.orderOut(nil)
        }
        if wasShowing {
            onDismiss?()
            let ok = succeeded
            succeeded = false
            onResult?(ok)
        }
    }

    // MARK: - Verification: did they click the thing?

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.handleClick(at: NSEvent.mouseLocation)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.dismiss() }   // esc
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handleClick(at point: CGPoint) {
        guard isShowing, let view = window?.contentView as? OverlayView else { return }
        if target.insetBy(dx: -4, dy: -4).contains(point) {
            succeeded = true
            view.markSuccess()
            timeout?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            strayClicks += 1
            if strayClicks >= 4 { dismiss() }
        }
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    private let cursor = CAShapeLayer()
    private let trail = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let label = NSVisualEffectView()
    private let labelText = NSTextField(labelWithString: "")
    private let noteText = NSTextField(wrappingLabelWithString: "")
    private var title = ""
    private var hasNote = false

    private static let cursorScale: CGFloat = 1.45
    private static let cursorSize = CGSize(width: 12.5, height: 20)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        configureCursor(trail, opacity: 0.32)
        configureCursor(cursor, opacity: 1)

        ring.fillColor = OverlayController.accent.withAlphaComponent(0.07).cgColor
        ring.strokeColor = OverlayController.accent.cgColor
        ring.lineWidth = 2.5
        ring.shadowColor = OverlayController.accent.cgColor
        ring.shadowRadius = 9
        ring.shadowOpacity = 0.7
        ring.shadowOffset = .zero
        ring.opacity = 0

        layer?.addSublayer(ring)
        layer?.addSublayer(trail)
        layer?.addSublayer(cursor)

        label.material = .hudWindow
        label.blendingMode = .behindWindow
        label.state = .active
        label.wantsLayer = true
        label.layer?.cornerRadius = 10
        label.layer?.cornerCurve = .continuous
        label.layer?.masksToBounds = true
        label.alphaValue = 0
        labelText.font = .systemFont(ofSize: 13, weight: .medium)
        labelText.textColor = .labelColor
        labelText.lineBreakMode = .byTruncatingTail
        labelText.maximumNumberOfLines = 1
        label.addSubview(labelText)
        noteText.font = .systemFont(ofSize: 12)
        noteText.textColor = .secondaryLabelColor
        noteText.maximumNumberOfLines = 2
        noteText.lineBreakMode = .byTruncatingTail
        label.addSubview(noteText)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - The cursor

    /// Classic arrow, y-up, tip at the top-left of its bounds.
    private static func arrowPath() -> CGPath {
        let pts: [CGPoint] = [
            CGPoint(x: 0, y: 20), CGPoint(x: 0, y: 4), CGPoint(x: 4, y: 7.5), CGPoint(x: 7, y: 1),
            CGPoint(x: 10, y: 2.5), CGPoint(x: 7, y: 9), CGPoint(x: 12.5, y: 9),
        ]
        let p = CGMutablePath()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        var t = CGAffineTransform(scaleX: cursorScale, y: cursorScale)
        return p.copy(using: &t) ?? p
    }

    private func configureCursor(_ l: CAShapeLayer, opacity: Float) {
        l.path = Self.arrowPath()
        l.bounds = CGRect(origin: .zero, size: CGSize(width: Self.cursorSize.width * Self.cursorScale,
                                                       height: Self.cursorSize.height * Self.cursorScale))
        l.anchorPoint = CGPoint(x: 0, y: 1)
        l.fillColor = OverlayController.accent.cgColor
        l.strokeColor = NSColor.white.cgColor
        l.lineWidth = 1.6
        l.lineJoin = .round
        l.shadowColor = OverlayController.accent.cgColor
        l.shadowRadius = 11
        l.shadowOpacity = 0.9
        l.shadowOffset = .zero
        l.opacity = opacity
    }

    // MARK: - Choreography

    func present(cursorFrom start: CGPoint, to end: CGPoint, highlighting rect: CGRect, verb: String, title: String, note: String? = nil) {
        self.title = title
        hasNote = !(note ?? "").isEmpty
        noteText.stringValue = note ?? ""
        noteText.isHidden = !hasNote
        let scale = window?.backingScaleFactor ?? 2
        [cursor, trail, ring].forEach { $0.contentsScale = scale }

        let ringRect = rect.insetBy(dx: -6, dy: -6)
        let now = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursor.position = end
        trail.position = end
        ring.frame = ringRect
        ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: ringRect.size), cornerWidth: 9, cornerHeight: 9, transform: nil)
        ring.opacity = 1
        CATransaction.commit()

        // Travel: the arc is the teaching, so it's a spring with a visible settle.
        let move = CASpringAnimation(keyPath: "position")
        move.fromValue = NSValue(point: start)
        move.toValue = NSValue(point: end)
        move.mass = 1; move.stiffness = 130; move.damping = 17
        move.duration = move.settlingDuration
        cursor.add(move, forKey: "move")

        let lag = CASpringAnimation(keyPath: "position")
        lag.fromValue = NSValue(point: start)
        lag.toValue = NSValue(point: end)
        lag.mass = 1; lag.stiffness = 70; lag.damping = 11
        lag.duration = lag.settlingDuration
        trail.add(lag, forKey: "move")

        // Arrival squash.
        let squash = CAKeyframeAnimation(keyPath: "transform.scale")
        squash.values = [1, 0.84, 1.06, 1]
        squash.keyTimes = [0, 0.35, 0.7, 1]
        squash.duration = 0.32
        squash.beginTime = now + move.settlingDuration * 0.55
        cursor.add(squash, forKey: "squash")

        // Ring reveal, then a slow pulse.
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1.18; grow.toValue = 1
        let reveal = CAAnimationGroup()
        reveal.animations = [fade, grow]
        reveal.duration = 0.38
        reveal.beginTime = now + 0.22
        reveal.fillMode = .backwards
        reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(reveal, forKey: "reveal")

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.55
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.beginTime = now + 0.75
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(pulse, forKey: "pulse")

        setLabel(verb: verb, title: title, near: ringRect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.label.animator().alphaValue = 1
        }
    }

    func markSuccess() {
        let green = NSColor.systemGreen
        ring.removeAnimation(forKey: "pulse")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        ring.strokeColor = green.cgColor
        ring.shadowColor = green.cgColor
        ring.fillColor = green.withAlphaComponent(0.1).cgColor
        ring.opacity = 1
        cursor.fillColor = green.cgColor
        cursor.shadowColor = green.cgColor
        trail.opacity = 0
        CATransaction.commit()

        let bump = CAKeyframeAnimation(keyPath: "transform.scale")
        bump.values = [1, 1.07, 1]
        bump.duration = 0.28
        ring.add(bump, forKey: "bump")

        let click = CAKeyframeAnimation(keyPath: "transform.scale")
        click.values = [1, 0.8, 1]
        click.duration = 0.22
        cursor.add(click, forKey: "click")

        labelText.attributedStringValue = attributed(prefix: "✓  ", title: title)
        layoutLabel(near: ring.frame)
    }

    // MARK: - Label

    private func attributed(prefix: String, title: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        return s
    }

    private func setLabel(verb: String, title: String, near rect: CGRect) {
        labelText.attributedStringValue = attributed(prefix: "\(verb)  ", title: title)
        layoutLabel(near: rect)
    }

    private func layoutLabel(near rect: CGRect) {
        labelText.sizeToFit()
        let padX: CGFloat = 12, padY: CGFloat = 7
        let maxW: CGFloat = 420
        var w = min(labelText.frame.width + padX * 2, maxW)
        var noteH: CGFloat = 0
        if hasNote {
            noteText.preferredMaxLayoutWidth = maxW - padX * 2
            let fit = noteText.sizeThatFits(NSSize(width: maxW - padX * 2, height: 60))
            noteH = min(fit.height, 34) + 3
            w = min(max(w, min(fit.width, maxW - padX * 2) + padX * 2), maxW)
        }
        let h = labelText.frame.height + noteH + padY * 2
        labelText.frame = NSRect(x: padX, y: padY + noteH, width: w - padX * 2, height: labelText.frame.height)
        noteText.frame = NSRect(x: padX, y: padY, width: w - padX * 2, height: max(0, noteH - 3))

        var y = rect.minY - 10 - h
        if y < 12 { y = rect.maxY + 10 }
        let x = min(max(12, rect.midX - w / 2), bounds.width - w - 12)
        label.frame = NSRect(x: x, y: y, width: w, height: h)
    }
}
