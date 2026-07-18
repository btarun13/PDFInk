import Foundation
import PDFKit
import PDFInkCore

/// Renders the document plus ink into a brand-new PDF, burning strokes into the
/// page content (no annotations), for "Export Flattened PDF".
enum FlattenedExporter {

    enum ExportError: LocalizedError {
        case cannotCreateContext
        var errorDescription: String? { "Couldn't create the output PDF." }
    }

    static func export(document: PDFDocument, store: StrokeStore, to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw ExportError.cannotCreateContext
        }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            var mediaBox = page.bounds(for: .mediaBox)
            let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            ctx.saveGState()
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            // Strokes are already in page space — draw straight into the PDF context.
            for stroke in store.strokes(onPage: pageIndex) {
                StrokeRenderer.draw(stroke, in: ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
