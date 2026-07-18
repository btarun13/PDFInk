import AppKit
import PDFKit

/// Page templates for notebook-style whiteboards. Backgrounds are drawn into
/// real PDF page content, so strokes annotate on top and any PDF reader shows
/// the same paper.
enum WhiteboardTemplate: String, CaseIterable {
    case blank
    case grid
    case lined

    static let pageSize = CGSize(width: 612, height: 792) // US Letter

    var displayName: String {
        switch self {
        case .blank: return "Blank"
        case .grid: return "Grid"
        case .lined: return "Lined"
        }
    }

    /// PDF data containing `pageCount` pages of this template.
    func pdfData(pageCount: Int = 1) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        for _ in 0..<max(pageCount, 1) {
            ctx.beginPDFPage(nil)
            draw(in: ctx, mediaBox: mediaBox)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// A single new page of this template (for Add Page).
    func makePage() -> PDFPage? {
        PDFDocument(data: pdfData(pageCount: 1))?.page(at: 0)
    }

    private func draw(in ctx: CGContext, mediaBox: CGRect) {
        ctx.setFillColor(.white)
        ctx.fill(mediaBox)

        switch self {
        case .blank:
            break

        case .grid:
            ctx.setStrokeColor(CGColor(red: 0.80, green: 0.85, blue: 0.92, alpha: 1))
            ctx.setLineWidth(0.5)
            let spacing: CGFloat = 25
            var x = spacing
            while x < mediaBox.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: mediaBox.height))
                x += spacing
            }
            var y = spacing
            while y < mediaBox.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: mediaBox.width, y: y))
                y += spacing
            }
            ctx.strokePath()

        case .lined:
            // Ruled lines with a top margin and a red left-margin rule.
            ctx.setStrokeColor(CGColor(red: 0.68, green: 0.78, blue: 0.90, alpha: 1))
            ctx.setLineWidth(0.6)
            let spacing: CGFloat = 28
            var y = mediaBox.height - 90
            while y > 40 {
                ctx.move(to: CGPoint(x: 40, y: y))
                ctx.addLine(to: CGPoint(x: mediaBox.width - 30, y: y))
                y -= spacing
            }
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(red: 0.93, green: 0.55, blue: 0.55, alpha: 1))
            ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: 78, y: 30))
            ctx.addLine(to: CGPoint(x: 78, y: mediaBox.height - 30))
            ctx.strokePath()
        }
    }
}
