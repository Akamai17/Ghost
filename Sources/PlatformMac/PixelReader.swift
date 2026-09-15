import AppKit
import ScreenCaptureKit
import Vision
import GuideKit

/// Reads text off the pixels of an app's front window. This is the fallback for apps whose
/// accessibility tree is hollow — Spotify and other Chromium/CEF shells expose only the window
/// chrome — and OCR gives us labels with frames, which is all pointing needs.
public enum PixelReader {
    public static let role = "AXOCRText"

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt the first time it's called; afterwards it just reports the state.
    @discardableResult public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    private static let warmed = NSLock()
    nonisolated(unsafe) private static var didWarm = false

    /// Vision spends ~25s loading its text model the first time a process uses it. Pay that at launch,
    /// off the main thread, so the first real walk through a hollow app isn't a stall. Safe to call repeatedly.
    public static func warmUp() {
        warmed.lock()
        let already = didWarm
        didWarm = true
        warmed.unlock()
        guard !already, hasPermission else { return }
        DispatchQueue.global(qos: .utility).async {
            let t = Date()
            let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            guard let img = ctx?.makeImage() else { return }
            _ = try? recognize(img, in: CGRect(x: 0, y: 0, width: 64, height: 64), startID: 0)
            Log.write("pixels: warmed Vision in \(ms(t, Date()))")
        }
    }

    /// True when the tree has essentially nothing inside the window: the signature of a web view that hides its controls.
    public static func isSparse(_ snap: Snapshot) -> Bool {
        let chrome: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
        let inside = snap.elements.filter {
            $0.isInteractive && $0.role != "AXMenuBarItem" && $0.role != "AXMenuItem" && !chrome.contains($0.subrole ?? "")
        }
        return inside.count < 5
    }

    /// OCR the app's front window. IDs continue from `startID` so the result can be appended to an AX snapshot.
    public static func read(pid: pid_t, startID: Int) async -> [UIElement] {
        guard hasPermission else { return [] }
        let t0 = Date()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let t1 = Date()
            // Front-to-back order, so the first sizable normal-layer window is the one the person is looking at.
            guard let win = content.windows.first(where: {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 200 && $0.frame.height >= 120
            }) else { return [] }

            var scale = NSScreen.main?.backingScaleFactor ?? 2
            if win.frame.width * scale > 3200 { scale = 3200 / win.frame.width }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.width = Int(win.frame.width * scale)
            config.height = Int(win.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let t2 = Date()
            let found = try recognize(image, in: win.frame, startID: startID)
            Log.write("pixels: windows \(ms(t0, t1)) capture \(ms(t1, t2)) ocr \(ms(t2, Date())) → \(found.count) labels (\(image.width)x\(image.height))")
            return found
        } catch {
            Log.write("pixels: \(error.localizedDescription)")
            return []
        }
    }

    private static func ms(_ a: Date, _ b: Date) -> String { "\(Int(b.timeIntervalSince(a) * 1000))ms" }

    private static func recognize(_ image: CGImage, in frame: CGRect, startID: Int) throws -> [UIElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // UI labels aren't prose; correction "fixes" product names
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        var out: [UIElement] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first, cand.confidence >= 0.3 else { continue }
            for piece in split(cand, imageSize: CGSize(width: image.width, height: image.height)) {
                let b = piece.box   // normalized, origin bottom-left
                let f = CGRect(x: frame.minX + b.minX * frame.width,
                               y: frame.minY + (1 - b.maxY) * frame.height,
                               width: b.width * frame.width, height: b.height * frame.height)
                guard f.width > 2, f.height > 2 else { continue }
                out.append(UIElement(id: startID + out.count, role: role, subrole: nil, labels: [piece.text], frame: f,
                                     isEnabled: true, depth: 1, ancestry: ["AXWindow"]))
            }
        }
        return out
    }

    private struct Piece { var text: String; var box: CGRect }

    /// Vision hands back whole lines, so a nav bar reads as "Home Search Your Library". Break a line
    /// wherever the gap between words is wider than most of a line height, which is where UI items end.
    private static func split(_ cand: VNRecognizedText, imageSize: CGSize) -> [Piece] {
        let s = cand.string
        var words: [(String, CGRect)] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace { i = s.index(after: i); continue }
            var j = i
            while j < s.endIndex, !s[j].isWhitespace { j = s.index(after: j) }
            if let r = try? cand.boundingBox(for: i..<j) { words.append((String(s[i..<j]), r.boundingBox)) }
            i = j
        }
        guard let first = words.first else { return [] }

        var pieces: [Piece] = []
        var cur = Piece(text: first.0, box: first.1)
        for (w, b) in words.dropFirst() {
            let gap = (b.minX - cur.box.maxX) * imageSize.width
            let lineHeight = max(cur.box.height, b.height) * imageSize.height
            if gap > lineHeight * 0.8 {
                pieces.append(cur)
                cur = Piece(text: w, box: b)
            } else {
                cur.text += " " + w
                cur.box = cur.box.union(b)
            }
        }
        pieces.append(cur)
        return pieces
    }
}
