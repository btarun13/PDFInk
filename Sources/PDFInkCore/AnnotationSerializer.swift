import Foundation
import PDFKit

/// Bridges the stroke model to PDFKit ink annotations so annotations are
/// visible in other readers (Preview, Acrobat).
public enum AnnotationSerializer {

    /// Title tag identifying annotations written by PDFInk, so re-saves can
    /// replace earlier ones instead of stacking duplicates.
    public static let annotationTitle = "PDFInk"

    /// Key under which the original stroke JSON is stashed for round-tripping.
    public static let strokePayloadKey = "/PDFInkStroke"

    // MARK: - Stroke → PDFAnnotation

    public static func annotation(for stroke: Stroke) -> PDFAnnotation {
        let bounds = stroke.pageBounds
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.userName = annotationTitle

        // PDFAnnotation paths are relative to the annotation's bounds origin.
        let path = NSBezierPath()
        let cgPath = StrokeGeometry.smoothedPath(stroke.samples)
        var transform = CGAffineTransform(translationX: -bounds.origin.x, y: -bounds.origin.y)
        if let shifted = cgPath.copy(using: &transform) {
            path.append(NSBezierPath(cgPath: shifted))
        }
        annotation.add(path)

        // Alpha goes into the color itself: PDFKit writes it as /CA on save,
        // and unlike a manually-set /CA key it also honors it when rendering.
        let alpha: CGFloat = stroke.tool == .highlighter ? 0.4 : stroke.color.alpha
        annotation.color = NSColor(calibratedRed: stroke.color.red,
                                   green: stroke.color.green,
                                   blue: stroke.color.blue,
                                   alpha: alpha)
        annotation.contents = nil

        let border = PDFBorder()
        border.lineWidth = averageWidth(of: stroke)
        annotation.border = border

        if stroke.tool == .highlighter {
            annotation.setValue("Multiply", forAnnotationKey: PDFAnnotationKey(rawValue: "/BM"))
        }

        // Stash full-fidelity stroke JSON (pressure per sample) for round-tripping.
        if let payload = try? JSONEncoder().encode(stroke) {
            annotation.setValue(payload.base64EncodedString(),
                                forAnnotationKey: PDFAnnotationKey(rawValue: strokePayloadKey))
        }
        return annotation
    }

    public static func averageWidth(of stroke: Stroke) -> CGFloat {
        guard !stroke.samples.isEmpty else {
            return StrokeGeometry.width(forPressure: 0.5, baseWidth: stroke.baseWidth, tool: stroke.tool)
        }
        let total = stroke.samples.reduce(CGFloat(0)) {
            $0 + StrokeGeometry.width(forPressure: $1.pressure, baseWidth: stroke.baseWidth, tool: stroke.tool)
        }
        return total / CGFloat(stroke.samples.count)
    }

    // MARK: - Document-level apply

    /// Removes previously-written PDFInk annotations and writes current strokes
    /// into `document`. Call on a copy of the display document when saving.
    public static func apply(store: StrokeStore, to document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.userName == annotationTitle {
                page.removeAnnotation(annotation)
            }
            for stroke in store.strokes(onPage: pageIndex) {
                page.addAnnotation(annotation(for: stroke))
            }
        }
    }

    // MARK: - PDFAnnotation → Stroke (round-trip)

    /// Recovers strokes previously saved by PDFInk from a document.
    public static func extractStrokes(from document: PDFDocument) -> [Stroke] {
        var strokes: [Stroke] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.userName == annotationTitle {
                guard let b64 = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: strokePayloadKey)) as? String,
                      let data = Data(base64Encoded: b64),
                      var stroke = try? JSONDecoder().decode(Stroke.self, from: data) else { continue }
                stroke.pageIndex = pageIndex
                strokes.append(stroke)
            }
        }
        return strokes
    }
}
