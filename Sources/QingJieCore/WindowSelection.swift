import CoreGraphics

/// A frozen window-list entry in Quartz global coordinates (top-left origin).
public struct CaptureWindow {
    public let id: UInt32
    public let ownerPID: Int32
    public let frame: CGRect
    public let layer: Int
    public let alpha: CGFloat
    public let isOnScreen: Bool
    public let name: String
    public let bundleIdentifier: String

    public init(id: UInt32, ownerPID: Int32, frame: CGRect, layer: Int = 0,
                alpha: CGFloat = 1, isOnScreen: Bool = true, name: String = "", bundleIdentifier: String = "") {
        self.id = id; self.ownerPID = ownerPID; self.frame = frame; self.layer = layer
        self.alpha = alpha; self.isOnScreen = isOnScreen; self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct WindowSelectionTarget: Equatable, Sendable {
    public let id: UInt32
    /// Clipped to one display, in top-left local points, just like a manual selection.
    public let rect: CGRect
    public let name: String
    /// Visually distinct panels belonging to this native window, outermost first.
    public let panels: [CGRect]
    public let browserContent: CGRect?
    public let canDetectBrowserContent: Bool

    public init(id: UInt32, rect: CGRect, name: String = "", panels: [CGRect] = [],
                browserContent: CGRect? = nil, canDetectBrowserContent: Bool = false) {
        self.id = id; self.rect = rect; self.name = name; self.panels = panels
        self.browserContent = browserContent; self.canDetectBrowserContent = canDetectBrowserContent
    }
}

public enum WindowSelection {
    /// Preserve the WindowServer's front-to-back order, including overlapping windows.
    public static func targets(from windows: [CaptureWindow], display: CGRect, localSize: CGSize,
                               excludingPID: Int32) -> [WindowSelectionTarget] {
        guard display.width > 0, display.height > 0, localSize.width > 0, localSize.height > 0 else { return [] }
        return windows.compactMap { window in
            // Normal windows and floating utility windows. Desktop, Dock, menu bar,
            // transient menus, invisible helpers and this app's UI aren't targets.
            guard window.ownerPID != excludingPID, window.isOnScreen, window.alpha > 0.01,
                  window.layer == 0 || window.layer == 3,
                  window.frame.width >= 24, window.frame.height >= 24,
                  window.frame.minX.isFinite, window.frame.minY.isFinite,
                  window.frame.width.isFinite, window.frame.height.isFinite else { return nil }
            let clipped = window.frame.intersection(display)
            guard !clipped.isNull, clipped.width >= 3, clipped.height >= 3 else { return nil }
            let sx = localSize.width / display.width, sy = localSize.height / display.height
            let rect = CGRect(x: (clipped.minX - display.minX) * sx, y: (clipped.minY - display.minY) * sy,
                              width: clipped.width * sx, height: clipped.height * sy)
            let chromium = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
                            "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser"]
            // A clipped header cannot establish the toolbar's full visual geometry.
            let completeHeader = clipped.minY == window.frame.minY && clipped.minX == window.frame.minX && clipped.maxX == window.frame.maxX
            return WindowSelectionTarget(id: window.id, rect: rect, name: window.name,
                                         canDetectBrowserContent: chromium.contains(window.bundleIdentifier) && completeHeader)
        }
    }

    public static func target(at point: CGPoint, in targets: [WindowSelectionTarget], wholeWindow: Bool = false) -> WindowSelectionTarget? {
        guard let window = targets.first(where: { $0.rect.contains(point) }) else { return nil }
        if !wholeWindow, let panel = window.panels.first(where: { $0.contains(point) }) {
            return WindowSelectionTarget(id: window.id, rect: panel, name: window.name + " · 应用内窗口")
        }
        if !wholeWindow, let content = window.browserContent, content.contains(point) {
            return WindowSelectionTarget(id: window.id, rect: content, name: window.name + " · 网页内容")
        }
        return window
    }
}
