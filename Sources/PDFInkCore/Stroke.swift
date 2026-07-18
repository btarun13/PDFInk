import Foundation
import CoreGraphics

/// Drawing tools available in the app.
public enum Tool: String, Codable, CaseIterable, Sendable {
    case pen
    case highlighter
    case eraser
    case lasso // stubbed for v1
}

/// A single input sample: a point in PDF page space plus stylus pressure.
public struct StrokeSample: Codable, Equatable, Sendable {
    /// Point in PDF page coordinates (origin bottom-left, unscaled).
    public var point: CGPoint
    /// Normalized pressure 0...1. Mouse/trackpad input uses a constant fallback.
    public var pressure: CGFloat

    public init(point: CGPoint, pressure: CGFloat) {
        self.point = point
        self.pressure = pressure
    }
}

/// RGBA color stored as components so the model stays Codable and AppKit-free.
public struct StrokeColor: Codable, Equatable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// One committed stroke: samples in PDF page space plus tool metadata.
public struct Stroke: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var tool: Tool
    public var color: StrokeColor
    /// Base width in PDF points at pressure ~0.5; actual segment widths scale with pressure.
    public var baseWidth: CGFloat
    /// Index of the page this stroke belongs to.
    public var pageIndex: Int
    public var samples: [StrokeSample]

    public init(id: UUID = UUID(),
                tool: Tool,
                color: StrokeColor,
                baseWidth: CGFloat,
                pageIndex: Int,
                samples: [StrokeSample] = []) {
        self.id = id
        self.tool = tool
        self.color = color
        self.baseWidth = baseWidth
        self.pageIndex = pageIndex
        self.samples = samples
    }

    /// Axis-aligned bounding box in page space, outset by the maximum possible width.
    public var pageBounds: CGRect {
        guard let first = samples.first else { return .null }
        var minX = first.point.x, maxX = first.point.x
        var minY = first.point.y, maxY = first.point.y
        for s in samples {
            minX = min(minX, s.point.x); maxX = max(maxX, s.point.x)
            minY = min(minY, s.point.y); maxY = max(maxY, s.point.y)
        }
        let pad = StrokeGeometry.width(forPressure: 1.0, baseWidth: baseWidth, tool: tool)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -pad, dy: -pad)
    }
}
