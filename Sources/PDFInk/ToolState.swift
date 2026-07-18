import AppKit
import PDFInkCore

/// Current tool/color/width selection, shared by toolbar, menus, and canvas.
final class ToolState {

    static let presetColors: [(name: String, color: StrokeColor)] = [
        ("Black", StrokeColor(red: 0.10, green: 0.10, blue: 0.10)),
        ("Blue", StrokeColor(red: 0.00, green: 0.35, blue: 0.95)),
        ("Red", StrokeColor(red: 0.90, green: 0.15, blue: 0.15)),
        ("Green", StrokeColor(red: 0.05, green: 0.60, blue: 0.25)),
        ("Yellow", StrokeColor(red: 1.00, green: 0.85, blue: 0.10)),
        ("Purple", StrokeColor(red: 0.55, green: 0.20, blue: 0.85)),
    ]

    /// Width presets in PDF points (pen maps 0.5–4pt at baseWidth 2).
    static let widthPresets: [(name: String, width: CGFloat)] = [
        ("Thin", 1.0), ("Medium", 2.0), ("Thick", 4.0),
    ]

    var onChange: (() -> Void)?

    var tool: Tool = .pen {
        didSet {
            if oldValue != tool, oldValue != .eraser { lastDrawingTool = oldValue }
            onChange?()
        }
    }

    /// The drawing tool to restore when the stylus eraser end leaves proximity.
    private(set) var lastDrawingTool: Tool = .pen

    var color: StrokeColor = ToolState.presetColors[0].color { didSet { onChange?() } }
    var baseWidth: CGFloat = 2.0 { didSet { onChange?() } }

    /// Called from tablet proximity handling when the stylus is flipped.
    func stylusEnteredProximity(isEraserEnd: Bool) {
        if isEraserEnd {
            if tool != .eraser { lastDrawingTool = tool }
            tool = .eraser
        } else if tool == .eraser {
            tool = lastDrawingTool == .eraser ? .pen : lastDrawingTool
        }
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    func setColor(from nsColor: NSColor) {
        guard let rgb = nsColor.usingColorSpace(.deviceRGB) else { return }
        color = StrokeColor(red: rgb.redComponent, green: rgb.greenComponent,
                            blue: rgb.blueComponent, alpha: 1.0)
    }
}
