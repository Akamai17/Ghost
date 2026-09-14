import AppKit
import SwiftUI
import ApplicationServices
import PlatformMac

@MainActor
final class PermissionsModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var apiKeyDraft = ""
    @Published var hasKey = Keychain.hasAPIKey

    func saveKey() {
        Keychain.apiKey = apiKeyDraft
        hasKey = Keychain.hasAPIKey
        apiKeyDraft = ""
    }

    func clearKey() {
        Keychain.apiKey = nil
        hasKey = false
    }
    private var timer: Timer?

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trusted = AXIsProcessTrusted() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func requestAccess() {
        // Go straight to the pane; the system's own "open System Settings?" alert would be a second, redundant prompt.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = PermissionsModel()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Ghost"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: PermissionsView(model: model, close: { [weak self] in self?.window?.close() }))
            w.delegate = self
            window = w
        }
        model.trusted = AXIsProcessTrusted()
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.stopPolling() }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    var close: () -> Void
    private var accent: Color { Color(nsColor: OverlayController.accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 56, height: 56)
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(accent)
                        .shadow(color: accent.opacity(0.8), radius: 8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ghost").font(.system(size: 22, weight: .bold))
                    Text("A cursor that shows you where to click.").foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 28)

            step(number: 1, done: model.trusted, title: "Allow Accessibility access",
                 detail: "Ghost reads the controls on screen so it can point at them. Nothing leaves your Mac.") {
                if !model.trusted {
                    Button("Open Accessibility Settings") { model.requestAccess() }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                }
            }

            Divider().padding(.vertical, 18)

            step(number: 2, done: false, title: "Summon it anywhere", detail: "Tap Control twice. Type what you're trying to do. Press Return.") {
                HStack(spacing: 6) {
                    keycap("⌃"); keycap("⌃")
                    Text("in any app").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 4)
                }
            }

            Divider().padding(.vertical, 18)

            step(number: 3, done: model.hasKey, title: "GhostBrain (optional)",
                 detail: "When a plain search can't find it, GhostBrain sends your goal, what's on screen, and your Mac's specs to Claude and walks you through the steps. Your key is kept in a private file only your user can read.") {
                if model.hasKey {
                    HStack(spacing: 10) {
                        Label("Key saved", systemImage: "key.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Remove") { model.clearKey() }.controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("sk-ant-…", text: $model.apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .onSubmit { model.saveKey() }
                        Button("Save") { model.saveKey() }
                            .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Spacer(minLength: 20)

            HStack {
                if model.trusted {
                    Label("Ready — try it in System Settings: ⌃⌃ then type “Wi‑Fi”", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.green)
                } else {
                    Label("Waiting for permission…", systemImage: "hourglass")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.trusted ? "Done" : "Later") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460, height: 560, alignment: .top)
    }

    private func step<Content: View>(number: Int, done: Bool, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.18)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content().padding(.top, 4)
            }
        }
    }

    private func keycap(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.secondary.opacity(0.25)))
    }
}
