import CoreGraphics

public enum RectCorner: CaseIterable, Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
    public var opposite: RectCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

public enum RectEdge: CaseIterable, Equatable {
    case top, bottom, left, right
    public var isHorizontal: Bool { self == .top || self == .bottom }
}

public enum RectResizeHandle: Equatable {
    case corner(RectCorner), edge(RectEdge)
}

public enum InteractionGeometry {
    /// Corners take precedence. Only a narrow band around each edge claims input.
    public static func resizeHandle(at point: CGPoint, rect: CGRect, cornerRadius: CGFloat = 9,
                                    edgeRadius: CGFloat = 6) -> RectResizeHandle? {
        if let corner = corner(at: point, rect: rect, radius: cornerRadius) { return .corner(corner) }
        var edges: [(RectEdge, CGFloat)] = []
        if point.x >= rect.minX && point.x <= rect.maxX {
            edges += [(.top, abs(point.y - rect.minY)), (.bottom, abs(point.y - rect.maxY))]
        }
        if point.y >= rect.minY && point.y <= rect.maxY {
            edges += [(.left, abs(point.x - rect.minX)), (.right, abs(point.x - rect.maxX))]
        }
        guard let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 <= edgeRadius else { return nil }
        return .edge(nearest.0)
    }

    public static func resize(_ rect: CGRect, handle: RectResizeHandle, to point: CGPoint,
                              bounds: CGRect, minimum: CGFloat = 3, square: Bool = false) -> CGRect {
        switch handle {
        case .corner(let corner): return resize(rect, corner: corner, to: point, bounds: bounds, minimum: minimum, square: square)
        case .edge(let edge):
            let horizontal = edge.isHorizontal
            let leading = edge == .top || edge == .left
            let anchor = horizontal ? (leading ? rect.maxY : rect.minY) : (leading ? rect.maxX : rect.minX)
            let lower = horizontal ? bounds.minY : bounds.minX, upper = horizontal ? bounds.maxY : bounds.maxX
            var moved = min(max(horizontal ? point.y : point.x, lower), upper)
            if abs(moved - anchor) < minimum {
                let direction: CGFloat = moved == anchor ? (leading ? -1 : 1) : (moved < anchor ? -1 : 1)
                moved = anchor + direction * minimum
                if moved < lower || moved > upper { moved = anchor - direction * minimum }
            }
            guard moved >= lower, moved <= upper, abs(moved - anchor) >= minimum else { return rect }
            // A side drag changes one axis, including when Shift is held.
            return horizontal
                ? CGRect(x: rect.minX, y: min(moved, anchor), width: rect.width, height: abs(moved - anchor))
                : CGRect(x: min(moved, anchor), y: rect.minY, width: abs(moved - anchor), height: rect.height)
        }
    }

    public static func corner(at point: CGPoint, rect: CGRect, radius: CGFloat) -> RectCorner? {
        RectCorner.allCases.first { corner in
            let center = corner.point(in: rect)
            return abs(center.x - point.x) <= radius && abs(center.y - point.y) <= radius
        }
    }

    /// Anchor the opposite corner. Crossing it is allowed; the rectangle stays normalized.
    public static func resize(_ rect: CGRect, corner: RectCorner, to point: CGPoint,
                              bounds: CGRect, minimum: CGFloat = 3, square: Bool = false) -> CGRect {
        let anchor = corner.opposite.point(in: rect)
        var point = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        if square {
            let dx = point.x - anchor.x, dy = point.y - anchor.y, length = min(abs(dx), abs(dy))
            point = CGPoint(x: anchor.x + (dx < 0 ? -length : length), y: anchor.y + (dy < 0 ? -length : length))
        }
        let resized = CaptureGeometry.rectangle(from: anchor, to: point)
        return resized.width >= minimum && resized.height >= minimum ? resized : rect
    }

    public static func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        let t = denominator > 0 ? min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator)) : 0
        return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
    }

    /// Top-left screen coordinates. Prefer a tall preview in an unused side strip.
    public static func scrollPreviewFrame(selection: CGRect, bounds: CGRect) -> CGRect {
        let margin: CGFloat = 12, idealWidth: CGFloat = 320, idealHeight: CGFloat = 680
        let available = bounds.insetBy(dx: margin, dy: margin)
        let sides = [CGRect(x: available.minX, y: available.minY, width: max(0, selection.minX - margin - available.minX), height: available.height),
                     CGRect(x: selection.maxX + margin, y: available.minY, width: max(0, available.maxX - selection.maxX - margin), height: available.height)]
        let vertical = [CGRect(x: available.minX, y: available.minY, width: available.width, height: max(0, selection.minY - margin - available.minY)),
                        CGRect(x: available.minX, y: selection.maxY + margin, width: available.width, height: max(0, available.maxY - selection.maxY - margin))]
        let space = sides.sorted { $0.width > $1.width }.first { $0.width >= 240 && $0.height >= 300 }
            ?? vertical.sorted { $0.height > $1.height }.first { $0.width >= 240 && $0.height >= 280 }
            ?? available
        let size = CGSize(width: min(idealWidth, space.width), height: min(idealHeight, space.height))
        return CGRect(x: space.midX - size.width / 2, y: space.midY - size.height / 2, width: size.width, height: size.height)
    }
}
