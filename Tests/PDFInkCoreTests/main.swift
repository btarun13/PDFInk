// Assertion-based test runner for PDFInkCore.
// (This machine's Command Line Tools ship no XCTest/swift-testing, so the test
// suite is a plain executable: `swift run PDFInkTests`.)
import Foundation
import AppKit
import PDFKit
import PDFInkCore

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String,
            file: String = #file, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [\((file as NSString).lastPathComponent):\(line)] \(message)")
    }
}

func expectClose(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 1e-4, _ message: String,
                 file: String = #file, line: Int = #line) {
    expect(abs(a - b) <= tol, "\(message) (\(a) vs \(b))", file: file, line: line)
}

func expectClose(_ a: CGPoint, _ b: CGPoint, tol: CGFloat = 1e-4, _ message: String,
                 file: String = #file, line: Int = #line) {
    expect(abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol,
           "\(message) (\(a) vs \(b))", file: file, line: line)
}

/// Builds an in-memory PDF with `pages` blank US-letter pages.
func makeTestDocument(pages: Int) -> PDFDocument {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    for _ in 0..<pages {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor.white)
        ctx.fill(mediaBox)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return PDFDocument(data: data as Data)!
}

// MARK: - Affine transform derivation

func testAffineTransformDerivation() {
    // Compose a known transform: scale, y-flip, translation (what a flipped,
    // zoomed view mapping looks like), derive it from three points, compare.
    for scale in [CGFloat(0.5), 1.0, 1.75, 3.0] {
        let truth = CGAffineTransform(translationX: 40, y: 900)
            .scaledBy(x: scale, y: -scale)
        let derived = StrokeGeometry.affineTransform(
            mappingOrigin: CGPoint.zero.applying(truth),
            unitX: CGPoint(x: 1, y: 0).applying(truth),
            unitY: CGPoint(x: 0, y: 1).applying(truth))
        for p in [CGPoint(x: 12.5, y: 34.25), CGPoint(x: 612, y: 792), CGPoint(x: -5, y: 1000)] {
            expectClose(p.applying(derived), p.applying(truth),
                        "derived transform matches truth at scale \(scale)")
            // Round-trip through the inverse must be the identity.
            expectClose(p.applying(derived).applying(derived.inverted()), p,
                        "inverse round-trip at scale \(scale)")
        }
    }
}

// MARK: - View ↔ page mapping through a real PDFView at multiple zoom levels

func testPDFViewCoordinateRoundTrip() {
    let document = makeTestDocument(pages: 3)
    let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.document = document
    pdfView.layoutDocumentView()

    guard let page = document.page(at: 1) else {
        expect(false, "page 1 exists"); return
    }
    let pagePoints = [CGPoint(x: 100, y: 200), CGPoint(x: 0, y: 0),
                      CGPoint(x: 306, y: 396), CGPoint(x: 611, y: 791)]

    for scale in [CGFloat(0.5), 1.0, 2.0, 4.0] {
        pdfView.scaleFactor = scale
        pdfView.layoutDocumentView()
        for p in pagePoints {
            let inView = pdfView.convert(p, from: page)
            let backToPage = pdfView.convert(inView, to: page)
            expectClose(backToPage, p, tol: 0.01,
                        "page→view→page round-trip at zoom \(scale)")
        }
        // A page-space point must land at the same page-relative position at
        // any zoom: check that view positions scale linearly with zoom.
        let origin = pdfView.convert(CGPoint.zero, from: page)
        let probe = pdfView.convert(CGPoint(x: 100, y: 100), from: page)
        expectClose(abs(probe.x - origin.x), 100 * scale, tol: 0.5,
                    "x offset scales with zoom \(scale)")
        expectClose(abs(probe.y - origin.y), 100 * scale, tol: 0.5,
                    "y offset scales with zoom \(scale)")
    }
}

// MARK: - Stroke → PDFAnnotation serialization

func testAnnotationSerialization() {
    let stroke = Stroke(tool: .pen,
                        color: StrokeColor(red: 0.9, green: 0.15, blue: 0.15),
                        baseWidth: 2.0,
                        pageIndex: 0,
                        samples: [
                            StrokeSample(point: CGPoint(x: 100, y: 100), pressure: 0.2),
                            StrokeSample(point: CGPoint(x: 150, y: 180), pressure: 0.6),
                            StrokeSample(point: CGPoint(x: 220, y: 140), pressure: 1.0),
                        ])
    let annotation = AnnotationSerializer.annotation(for: stroke)
    expect(annotation.type?.lowercased().contains("ink") == true,
           "annotation is ink type (got \(annotation.type ?? "nil"))")
    for s in stroke.samples {
        expect(annotation.bounds.contains(s.point), "bounds contain sample \(s.point)")
    }
    expect((annotation.paths?.count ?? 0) > 0, "annotation has at least one path")
    expect(annotation.userName == AnnotationSerializer.annotationTitle, "annotation tagged as PDFInk")

    let border = annotation.border
    expect(border != nil && border!.lineWidth > 0.4 && border!.lineWidth < 4.1,
           "border width in pen range (got \(border?.lineWidth ?? -1))")

    // Highlighter: constant width, alpha + multiply blend keys present.
    let highlight = Stroke(tool: .highlighter,
                           color: StrokeColor(red: 1, green: 0.85, blue: 0.1),
                           baseWidth: 2.0, pageIndex: 1,
                           samples: stroke.samples)
    let hAnnotation = AnnotationSerializer.annotation(for: highlight)
    // Alpha is carried in the annotation color; PDFKit renders it and writes /CA.
    let hAlpha = hAnnotation.color.alphaComponent
    expect(abs(hAlpha - 0.4) < 1e-6, "highlighter color alpha is 0.4 (got \(hAlpha))")

    // Full round-trip through a real document: apply, save to data, reload, extract.
    let document = makeTestDocument(pages: 2)
    let store = StrokeStore()
    store.add(stroke)
    store.add(highlight)
    AnnotationSerializer.apply(store: store, to: document)
    guard let data = document.dataRepresentation(),
          let reloaded = PDFDocument(data: data) else {
        expect(false, "document serializes and reloads"); return
    }
    let recovered = AnnotationSerializer.extractStrokes(from: reloaded)
    expect(recovered.count == 2, "recovered 2 strokes (got \(recovered.count))")
    if let recoveredPen = recovered.first(where: { $0.tool == .pen }) {
        expect(recoveredPen.samples == stroke.samples, "pen samples+pressures round-trip exactly")
        expect(recoveredPen.color == stroke.color, "pen color round-trips")
        expect(recoveredPen.pageIndex == 0, "pen page index round-trips")
    } else {
        expect(false, "pen stroke recovered")
    }

    // Re-applying must replace, not stack, PDFInk annotations.
    AnnotationSerializer.apply(store: store, to: document)
    let page0Count = document.page(at: 0)!.annotations.filter { $0.userName == AnnotationSerializer.annotationTitle }.count
    expect(page0Count == 1, "re-apply replaces annotations (got \(page0Count) on page 0)")
}

// MARK: - Store, geometry, misc

func testStoreAndGeometry() {
    let store = StrokeStore()
    let s1 = Stroke(tool: .pen, color: StrokeColor(red: 0, green: 0, blue: 0), baseWidth: 2,
                    pageIndex: 0, samples: [StrokeSample(point: CGPoint(x: 10, y: 10), pressure: 0.5),
                                            StrokeSample(point: CGPoint(x: 60, y: 10), pressure: 0.5)])
    let s2 = Stroke(tool: .pen, color: StrokeColor(red: 0, green: 0, blue: 0), baseWidth: 2,
                    pageIndex: 0, samples: [StrokeSample(point: CGPoint(x: 10, y: 40), pressure: 0.5),
                                            StrokeSample(point: CGPoint(x: 60, y: 40), pressure: 0.5)])
    store.add(s1); store.add(s2)

    expect(store.hitTest(point: CGPoint(x: 35, y: 11), pageIndex: 0, tolerance: 4)?.id == s1.id,
           "hitTest finds stroke near segment")
    expect(store.hitTest(point: CGPoint(x: 35, y: 25), pageIndex: 0, tolerance: 4) == nil,
           "hitTest misses far point")

    let removed = store.remove(id: s1.id, pageIndex: 0)
    expect(removed?.id == s1.id, "remove returns stroke")
    store.insert(s1, at: 0)
    expect(store.strokes(onPage: 0).first?.id == s1.id, "insert restores z-order")

    if let json = try? store.jsonData(), let reloaded = try? StrokeStore.load(from: json) {
        expect(reloaded.strokes(onPage: 0) == store.strokes(onPage: 0), "store JSON round-trip")
    } else {
        expect(false, "store JSON encode/decode")
    }

    // Pressure→width: spec range 0.5–4pt at the medium preset.
    expectClose(StrokeGeometry.width(forPressure: 0, baseWidth: 2, tool: .pen), 0.5, "min pen width")
    expectClose(StrokeGeometry.width(forPressure: 1, baseWidth: 2, tool: .pen), 4.0, "max pen width")
    expectClose(StrokeGeometry.width(forPressure: 0.5, baseWidth: 2, tool: .pen), 2.25, "mid pen width")

    // Catmull-Rom segments must chain continuously through the input points.
    let samples = (0..<6).map { i in
        StrokeSample(point: CGPoint(x: CGFloat(i) * 20, y: sin(CGFloat(i)) * 30), pressure: 0.5)
    }
    let segs = StrokeGeometry.catmullRomSegments(samples)
    expect(segs.count == samples.count - 1, "segment count")
    for i in 0..<segs.count {
        expectClose(segs[i].start, samples[i].point, "segment \(i) starts at sample")
        expectClose(segs[i].end, samples[i + 1].point, "segment \(i) ends at next sample")
        if i > 0 { expectClose(segs[i].start, segs[i - 1].end, "segment \(i) continuous") }
    }
}

// MARK: - Run

testAffineTransformDerivation()
testPDFViewCoordinateRoundTrip()
testAnnotationSerialization()
testStoreAndGeometry()

if failures == 0 {
    print("ALL \(checks) CHECKS PASSED")
    exit(0)
} else {
    print("\(failures)/\(checks) CHECKS FAILED")
    exit(1)
}
