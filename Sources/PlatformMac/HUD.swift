import AppKit
import SwiftUI
import GuideKit

public enum HUDLayout {
    public static let width: CGFloat = 600
    public static let inputHeight: CGFloat = 64
    public static let rowHeight: CGFloat = 44
    public static let rowSpacing: CGFloat = 2
    public static let listPadding: CGFloat = 6
    public static let footerHeight: CGFloat = 28
    public static let maxRows = 5
    public static let corner: CGFloat = 18

    public static let suggestionsHeader: CGFloat = 30
    public static let adviceHeight: CGFloat = 132

    public static func height(rows n: Int, suggestionsHeader header: Bool, advice: Bool = false) -> CGFloat {
        var h = inputHeight + footerHeight
        if advice { return h + 1 + adviceHeight }
        if header { h += 1 + suggestionsHeader }
        if n > 0 { h += (header ? 0 : 1) + listPadding * 2 + CGFloat(n) * rowHeight + CGFloat(n - 1) * rowSpacing }
        return h
    }
}

// MARK: - Model

public enum HUDRow: Hashable, Identifiable {
    case element(UIElement)
    case brain
    public var id: String {
        switch self {
        case .element(let e): return "e\(e.id)"
        case .brain: return "brain"
        }
    }
}

public enum BrainState: Equatable {
    case idle
    case thinking
    case advice(String)
    case error(String)
}

@MainActor
public final class HUDModel: ObservableObject {
    @Published public var query = "" { didSet { if brainState != .thinking { brainState = .idle }; refilter() } }
    @Published public var brainState: BrainState = .idle { didSet { onResultsChanged?() } }
    var onBrain: ((String) -> Void)?
    var onSetupBrain: (() -> Void)?

    public var showingAdvice: Bool {
        if case .advice = brainState { return true }
        if case .error = brainState { return true }
        return false
    }
    @Published public var results: [Match] = []
    @Published public var suggestions: [UIElement] = []
    @Published public var suggestionsExpanded = UserDefaults.standard.object(forKey: "hud.suggestionsExpanded") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(suggestionsExpanded, forKey: "hud.suggestionsExpanded")
            selected = 0
            onResultsChanged?()
        }
    }
    @Published public var selected = 0
    @Published public var status = ""
    @Published public var appName = ""

    public var snapshot: Snapshot? { didSet { rebuildSuggestions(); refilter() } }
    public var bundleID: String?

    /// Whether the query is empty and suggestions are what's on offer.
    public var showingSuggestions: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && !suggestions.isEmpty }
    /// The rows currently on screen, whichever source they come from.
    public var visible: [HUDRow] {
        if showingAdvice || brainState == .thinking { return [] }
        if showingSuggestions { return suggestionsExpanded ? suggestions.map { .element($0) } : [] }
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return results.map { .element($0.element) } + [.brain]
    }
    weak var textField: NSTextField?
    var onCommit: ((UIElement) -> Void)?
    var onCancel: (() -> Void)?
    var onResultsChanged: (() -> Void)?

    func reset(appName: String, bundleID: String?) {
        self.appName = appName
        self.bundleID = bundleID
        snapshot = nil
        query = ""
        results = []
        suggestions = []
        selected = 0
        brainState = .idle
        status = "Reading \(appName)…"
        onResultsChanged?()
    }

    private func rebuildSuggestions() {
        guard let snap = snapshot else { suggestions = []; return }
        suggestions = Suggester.pick(from: snap.elements, preferred: CuratedSuggestions.names(for: bundleID), limit: HUDLayout.maxRows)
    }

    func refilter() {
        guard let snap = snapshot else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        let before = visible.count
        let beforeHeader = showingSuggestions
        if q.isEmpty {
            results = []
            status = "\(snap.elements.count) controls in \(appName)\(snap.truncated ? " (partial)" : "") · \(Int(snap.duration * 1000))ms"
        } else {
            results = Matcher.rank(q, in: snap.elements, limit: HUDLayout.maxRows)
            status = results.isEmpty ? "Nothing matching “\(q)” in \(appName)" : "\(results.count) match\(results.count == 1 ? "" : "es")"
        }
        selected = 0
        if visible.count != before || showingSuggestions != beforeHeader { onResultsChanged?() }
    }

    func moveSelection(_ delta: Int) {
        let n = visible.count
        guard n > 0 else { return }
        selected = (selected + delta + n) % n
    }

    func toggleSuggestions() {
        guard showingSuggestions else { return }
        suggestionsExpanded.toggle()
    }

    func commit() {
        let rows = visible
        guard selected < rows.count else { return }
        switch rows[selected] {
        case .element(let e): onCommit?(e)
        case .brain: askBrain()
        }
    }

    func askBrain() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, brainState != .thinking else { return }
        onBrain?(q)
    }
}

// MARK: - Panel

final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: HUDLayout.width, height: HUDLayout.height(rows: 0, suggestionsHeader: false)),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class HUDController {
    public let model = HUDModel()
    public private(set) var isShowing = false
    public var onCommit: ((UIElement, NSRunningApplication) -> Void)?
    public var onBrain: ((String, Snapshot, NSRunningApplication) -> Void)?
    public var onSetupBrain: (() -> Void)?
    public var currentApp: NSRunningApplication? { app }

    private let panel = HUDPanel()
    private var app: NSRunningApplication?
    private var generation = 0
    private var resignObserver: Any?

    public init() {
        let hosting = NSHostingView(rootView: HUDView(model: model))
        panel.contentView = hosting
        model.onCommit = { [weak self] el in self?.commit(el) }
        model.onCancel = { [weak self] in self?.hide() }
        model.onResultsChanged = { [weak self] in self?.resize() }
        model.onBrain = { [weak self] q in
            guard let self, let app = self.app else { return }
            guard Keychain.hasAPIKey else { self.hide(); self.onSetupBrain?(); return }
            guard let snap = self.model.snapshot else { return }
            self.model.brainState = .thinking
            self.model.status = "GhostBrain is looking at \(self.model.appName)…"
            self.onBrain?(q, snap, app)
        }
        model.onSetupBrain = { [weak self] in self?.hide(); self?.onSetupBrain?() }
    }

    /// Called by the app once the model answers. Advice keeps the HUD open; a plan closes it.
    public func brainAnswered(_ result: Result<BrainPlan, Error>) -> BrainPlan? {
        switch result {
        case .success(let plan):
            if plan.found, !plan.steps.isEmpty {
                model.brainState = .idle
                hide()
                return plan
            }
            model.brainState = .advice(plan.advice.isEmpty ? plan.summary : plan.advice)
            model.status = plan.summary.isEmpty ? "GhostBrain" : plan.summary
            return nil
        case .failure(let err):
            model.brainState = .error(err.localizedDescription)
            model.status = "GhostBrain couldn't answer"
            return nil
        }
    }

    public func showMessage(_ text: String) {
        model.status = text
    }

    public func show(for app: NSRunningApplication) {
        self.app = app
        generation += 1
        let gen = generation
        model.reset(appName: app.localizedName ?? "this app", bundleID: app.bundleIdentifier)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let h = HUDLayout.height(rows: 0, suggestionsHeader: false)
        panel.setFrame(NSRect(x: vf.midX - HUDLayout.width / 2, y: vf.maxY - 150 - h, width: HUDLayout.width, height: h), display: false)

        panel.makeKeyAndOrderFront(nil)
        isShowing = true
        focus()

        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let snap = Sight.snapshot(of: app)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.model.snapshot = snap
            }
        }
    }

    public func hide() {
        guard isShowing else { return }
        isShowing = false
        generation += 1
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        panel.orderOut(nil)
    }

    private func commit(_ element: UIElement) {
        guard let app else { return }
        hide()
        onCommit?(element, app)
    }

    private func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let tf = self.model.textField else { return }
            self.panel.makeFirstResponder(tf)
            tf.currentEditor()?.selectAll(nil)
        }
    }

    private func resize() {
        let h = HUDLayout.height(rows: min(model.visible.count, HUDLayout.maxRows + 1), suggestionsHeader: model.showingSuggestions, advice: model.showingAdvice)
        var f = panel.frame
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        panel.setFrame(f, display: true, animate: false)
    }
}

// MARK: - View

struct HUDView: View {
    @ObservedObject var model: HUDModel
    private var accent: Color { Color(nsColor: OverlayController.accent) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 24)
                FocusTextField(model: model, placeholder: "What do you want to do in \(model.appName)?")
                if model.brainState == .thinking {
                    ProgressView().controlSize(.small)
                }
                Text("esc")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.6)))
            }
            .padding(.horizontal, 18)
            .frame(height: HUDLayout.inputHeight)

            if model.showingSuggestions {
                Rectangle().fill(.quaternary).frame(height: 1)
                Button { model.toggleSuggestions() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(model.suggestionsExpanded ? 90 : 0))
                            .animation(.easeOut(duration: 0.15), value: model.suggestionsExpanded)
                        Text("Suggestions")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(model.suggestions.count)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .frame(height: HUDLayout.suggestionsHeader)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if model.showingAdvice {
                Rectangle().fill(.quaternary).frame(height: 1)
                adviceBlock
            }

            let rows = model.visible
            if !rows.isEmpty {
                if !model.showingSuggestions { Rectangle().fill(.quaternary).frame(height: 1) }
                VStack(spacing: HUDLayout.rowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        Group {
                            switch r {
                            case .element(let e): row(e, selected: i == model.selected)
                            case .brain: brainRow(selected: i == model.selected, lonely: rows.count == 1)
                            }
                        }
                        .onTapGesture { model.selected = i; model.commit() }
                    }
                }
                .padding(HUDLayout.listPadding)
            }

            HStack {
                Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.showingAdvice {
                    Text("esc close").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else if !rows.isEmpty {
                    Text("↑↓ choose   ↩ show me   ⌘↩ GhostBrain").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else if model.showingSuggestions {
                    Text("⇥ suggestions").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: HUDLayout.footerHeight)
        }
        .frame(width: HUDLayout.width)
        .background(backdrop)
        .clipShape(RoundedRectangle(cornerRadius: HUDLayout.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HUDLayout.corner, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }

    @ViewBuilder private var backdrop: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: HUDLayout.corner))
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    private var adviceBlock: some View {
        let (text, isError): (String, Bool) = {
            switch model.brainState {
            case .advice(let t): return (t, false)
            case .error(let t): return (t, true)
            default: return ("", false)
            }
        }()
        return ScrollView {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle" : "brain")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isError ? Color.orange : accent)
                    .frame(width: 22)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(isError ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(height: HUDLayout.adviceHeight)
    }

    private func brainRow(selected: Bool, lonely: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? accent : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(lonely ? "Ask GhostBrain" : "Not what you're looking for? Use GhostBrain")
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(Keychain.hasAPIKey ? "Sends what's on screen + your Mac's specs to Claude" : "Needs an API key — set up in Settings")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("⌘↩").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: HUDLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? accent.opacity(0.16) : .clear))
        .contentShape(Rectangle())
    }

    private func row(_ e: UIElement, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: e))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? accent : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                let crumb = e.breadcrumb
                if !crumb.isEmpty {
                    Text(crumb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(e.roleName).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: HUDLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? accent.opacity(0.16) : .clear))
        .contentShape(Rectangle())
    }

    private func icon(for e: UIElement) -> String {
        switch e.role {
        case "AXButton", "AXMenuButton", "AXPopUpButton": return "button.horizontal"
        case "AXMenuItem", "AXMenuBarItem": return "filemenu.and.selection"
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": return "character.cursor.ibeam"
        case "AXCheckBox", "AXSwitch": return "checkmark.square"
        case "AXRadioButton": return "circle.inset.filled"
        case "AXLink": return "link"
        case "AXTab": return "rectangle.topthird.inset.filled"
        case "AXStaticText", "AXHeading": return "text.alignleft"
        case "AXOCRText": return "text.viewfinder"
        case "AXImage": return "photo"
        case "AXRow", "AXCell": return "list.bullet"
        case "AXSlider", "AXIncrementor", "AXStepper": return "slider.horizontal.3"
        case "AXDisclosureTriangle": return "chevron.right"
        default: return "square.dashed"
        }
    }
}

/// AppKit text field so first-responder handling and arrow/enter/esc are predictable
/// inside a non-activating panel.
struct FocusTextField: NSViewRepresentable {
    @ObservedObject var model: HUDModel
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 22, weight: .regular)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.delegate = context.coordinator
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        model.textField = tf
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != model.query { tf.stringValue = model.query }
        if tf.placeholderString != placeholder {
            tf.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: HUDModel
        init(model: HUDModel) { self.model = model }

        func controlTextDidChange(_ n: Notification) {
            guard let tf = n.object as? NSTextField else { return }
            model.query = tf.stringValue
        }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            model.brainState != .thinking
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): model.moveSelection(-1); return true
            case #selector(NSResponder.moveDown(_:)): model.moveSelection(1); return true
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { model.askBrain() } else { model.commit() }
                return true
            case #selector(NSResponder.cancelOperation(_:)): model.onCancel?(); return true
            case #selector(NSResponder.insertTab(_:)):
                if model.showingSuggestions { model.toggleSuggestions() } else { model.moveSelection(1) }
                return true
            default: return false
            }
        }
    }
}
