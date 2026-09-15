import AppKit
import GuideKit

/// Everything Ghost can see in an app: the accessibility tree first, and when that is hollow,
/// text read off the pixels. Blocking; call it off the main thread.
public enum Sight {
    public static func snapshot(of app: NSRunningApplication) -> Snapshot {
        let ax = AXReader.snapshot(of: app)
        guard PixelReader.isSparse(ax), PixelReader.hasPermission else { return ax }

        let pid = app.processIdentifier
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.elements = await PixelReader.read(pid: pid, startID: ax.elements.count)
            done.signal()
        }
        done.wait()
        return Snapshot(appName: ax.appName, pid: ax.pid, elements: ax.elements + box.elements,
                        capturedAt: ax.capturedAt, truncated: ax.truncated,
                        duration: Date().timeIntervalSince(ax.capturedAt))
    }

    private final class ResultBox: @unchecked Sendable { var elements: [UIElement] = [] }
}
