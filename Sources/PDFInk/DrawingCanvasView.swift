import AppKit
import PDFKit
import PDFInkCore

/// Transparent overlay covering the PDFView. Captures pen/mouse/tablet input,
/// maps it to PDF page space, renders live strokes incrementally, and blits
/// per-page bitmap caches of committed strokes.
///
/// Coordinate model: stroke samples are stored in PDF page space (origin
/// bottom-left, unscaled points). All page↔view mapping goes through
/// PDFView's convert APIs, so strokes stay registered at any zoom level.
final class DrawingCanvasView: NSView {

    weak var pdfView: PDFView?
    let store: StrokeStore
    let toolState: ToolState

    // MARK: Live stroke state (page space)
    private var activeSamples: [StrokeSample] = []
    private var activePage: PDFPage?
    private var activePageIndex: Int = -1
    private var lastSampleViewPoints: [CGPoint] = [] // for incremental invalidation
    private var tiltLogCounter = 0

    /// True while the stylus in proximity is the eraser end (set via proximity events).
    private var stylusIsEraserEnd = false
    private var proximityMonitor: Any?

    // MARK: Committed-stroke bitmap caches, one per page
    private final class PageCache {
        let context: CGContext
        var image: CGImage?
        let pageRectInView: CGRect
        let scaleFactor: CGFloat
        init(context: CGContext, pageRectInView: CGRect, scaleFactor: CGFloat) {
            self.context = context
            self.pageRectInView = pageRectInView
            self.scaleFactor = scaleFactor
        }
    }
    private var pageCaches: [Int: PageCache] = [:]

    private var notificationTokens: [NSObjectProtocol] = []

    // MARK: - Init

    init(pdfView: PDFView, store: StrokeStore, toolState: ToolState) {
        self.pdfView = pdfView
        self.store = store
        self.toolState = toolState
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true

        proximityMonitor = NSEvent.addLocalMonitorForEvents(matching: .tabletProximity) { [weak self] event in
            self?.handleProximity(event)
            return event
        }
        observePDFViewChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let proximityMonitor { NSEvent.removeMonitor(proximityMonitor) }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// Called by the owner whenever the stroke store mutates (draw/erase/undo).
    func storeDidChange(pageIndex: Int) {
        invalidateCache(forPage: pageIndex)
        needsDisplay = true
    }

    /// Called by the owner when the active tool/color/width changes.
    func toolStateDidChange() {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - PDFView observation

    private func observePDFViewChanges() {
        guard let pdfView else { return }
        let nc = NotificationCenter.default

        notificationTokens.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.invalidateAllCaches()
        })
        notificationTokens.append(nc.addObserver(forName: .PDFViewDocumentChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.invalidateAllCaches()
        })
        notificationTokens.append(nc.addObserver(forName: .PDFViewVisiblePagesChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.evictOffscreenCaches()
            self?.needsDisplay = true
        })
        // PDFView hosts an internal NSScrollView; observe scrolling so the
        // overlay re-blits its caches at the new offsets.
        if let scrollView = Self.findScrollView(in: pdfView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            notificationTokens.append(nc.addObserver(forName: NSView.boundsDidChangeNotification,
                                                     object: scrollView.contentView, queue: .main) { [weak self] _ in
                // Scrolling moves pages under the static overlay; page rects in
                // view space change, so cached placements must be recomputed.
                self?.invalidateAllCaches()
            })
        } else {
            NSLog("PDFInk: WARNING - couldn't find PDFView's scroll view; scroll redraw may lag")
        }
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView { return scroll }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Cache management

    private func invalidateAllCaches() {
        pageCaches.removeAll()
        needsDisplay = true
    }

    private func invalidateCache(forPage pageIndex: Int) {
        pageCaches.removeValue(forKey: pageIndex)
    }

    private func evictOffscreenCaches() {
        guard let pdfView, let document = pdfView.document else { return }
        let visible = Set(pdfView.visiblePages.map { document.index(for: $0) })
        pageCaches = pageCaches.filter { visible.contains($0.key) }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    /// Builds (or returns) the bitmap cache of committed strokes for a page.
    private func cache(forPage pageIndex: Int, page: PDFPage) -> PageCache? {
        guard let pdfView else { return nil }
        let pageRect = pageRectInView(for: page)
        if let existing = pageCaches[pageIndex],
           existing.pageRectInView == pageRect,
           existing.scaleFactor == pdfView.scaleFactor {
            return existing
        }
        let bscale = backingScale
        let pixelW = Int((pageRect.width * bscale).rounded(.up))
        let pixelH = Int((pageRect.height * bscale).rounded(.up))
        guard pixelW > 0, pixelH > 0, pixelW < 12000, pixelH < 12000,
              let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Page space → bitmap pixels: apply page→view transform, shift the page
        // rect to the origin, then scale up to backing pixels.
        ctx.scaleBy(x: bscale, y: bscale)
        ctx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
        ctx.concatenate(pageToViewTransform(for: page))

        for stroke in store.strokes(onPage: pageIndex) {
            StrokeRenderer.draw(stroke, in: ctx)
        }

        let cache = PageCache(context: ctx, pageRectInView: pageRect, scaleFactor: pdfView.scaleFactor)
        cache.image = ctx.makeImage()
        pageCaches[pageIndex] = cache
        return cache
    }

    // MARK: - Coordinate mapping

    private func pageRectInView(for page: PDFPage) -> CGRect {
        guard let pdfView else { return .zero }
        let bounds = page.bounds(for: pdfView.displayBox)
        let rectInPDFView = pdfView.convert(bounds, from: page)
        return convert(rectInPDFView, from: pdfView)
    }

    /// Exact affine transform mapping page space → overlay view space, derived
    /// from three reference points so scale/translation/rotation/flip are all
    /// captured. (Unit-testable core in StrokeGeometry.affineTransform.)
    private func pageToViewTransform(for page: PDFPage) -> CGAffineTransform {
        func toView(_ p: CGPoint) -> CGPoint {
            guard let pdfView else { return p }
            return convert(pdfView.convert(p, from: page), from: pdfView)
        }
        return StrokeGeometry.affineTransform(mappingOrigin: toView(.zero),
                                              unitX: toView(CGPoint(x: 1, y: 0)),
                                              unitY: toView(CGPoint(x: 0, y: 1)))
    }

    private func viewToPage(_ viewPoint: CGPoint, page: PDFPage) -> CGPoint {
        guard let pdfView else { return viewPoint }
        return pdfView.convert(convert(viewPoint, to: pdfView), to: page)
    }

    private func pageToView(_ pagePoint: CGPoint, page: PDFPage) -> CGPoint {
        guard let pdfView else { return pagePoint }
        return convert(pdfView.convert(pagePoint, from: page), from: pdfView)
    }

    private func page(at viewPoint: CGPoint) -> (PDFPage, Int)? {
        guard let pdfView, let document = pdfView.document else { return nil }
        let pointInPDFView = convert(viewPoint, to: pdfView)
        guard let page = pdfView.page(for: pointInPDFView, nearest: false) else { return nil }
        return (page, document.index(for: page))
    }

    // MARK: - Input

    private func pressure(for event: NSEvent) -> CGFloat {
        if event.subtype == .tabletPoint {
            return CGFloat(max(0, min(1, event.pressure)))
        }
        return 0.5 // constant fallback for mouse/trackpad
    }

    private func logTiltIfTablet(_ event: NSEvent) {
        guard event.subtype == .tabletPoint else { return }
        tiltLogCounter += 1
        if tiltLogCounter % 60 == 1 {
            let tilt = event.tilt
            NSLog("PDFInk: tablet tilt x=%.3f y=%.3f pressure=%.3f", tilt.x, tilt.y, event.pressure)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard pdfView?.document != nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let (page, pageIndex) = page(at: viewPoint) else { return }

        let effectiveTool = stylusIsEraserEnd ? .eraser : toolState.tool
        switch effectiveTool {
        case .eraser:
            erase(at: viewPoint, page: page, pageIndex: pageIndex)
        case .lasso:
            NSLog("PDFInk: lasso select is not implemented yet")
        case .pen, .highlighter:
            activePage = page
            activePageIndex = pageIndex
            activeSamples = [StrokeSample(point: viewToPage(viewPoint, page: page),
                                          pressure: pressure(for: event))]
            lastSampleViewPoints = [viewPoint]
        }
        logTiltIfTablet(event)
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let effectiveTool = stylusIsEraserEnd ? .eraser : toolState.tool

        if effectiveTool == .eraser {
            if let (page, pageIndex) = page(at: viewPoint) {
                erase(at: viewPoint, page: page, pageIndex: pageIndex)
            }
            return
        }
        guard let activePage else { return }

        let pagePoint = viewToPage(viewPoint, page: activePage)
        // Drop near-duplicate points from high-frequency tablet input.
        if let last = activeSamples.last,
           StrokeGeometry.squaredDistance(last.point, pagePoint) < 0.12 {
            return
        }
        activeSamples.append(StrokeSample(point: pagePoint, pressure: pressure(for: event)))
        logTiltIfTablet(event)

        // Incremental redraw: only the region around the newest segments.
        // Catmull-Rom control points of the previous segment shift when a new
        // point arrives, so invalidate the last few sample positions.
        lastSampleViewPoints.append(viewPoint)
        if lastSampleViewPoints.count > 5 { lastSampleViewPoints.removeFirst() }
        setNeedsDisplay(invalidationRect(around: lastSampleViewPoints))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            activeSamples = []
            activePage = nil
            activePageIndex = -1
            lastSampleViewPoints = []
        }
        let effectiveTool = stylusIsEraserEnd ? .eraser : toolState.tool
        guard effectiveTool == .pen || effectiveTool == .highlighter,
              activePage != nil, !activeSamples.isEmpty else { return }

        let stroke = Stroke(tool: effectiveTool,
                            color: toolState.color,
                            baseWidth: toolState.baseWidth,
                            pageIndex: activePageIndex,
                            samples: activeSamples)
        performAdd(stroke)
    }

    private func invalidationRect(around viewPoints: [CGPoint]) -> CGRect {
        guard let first = viewPoints.first else { return bounds }
        var rect = CGRect(origin: first, size: .zero)
        for p in viewPoints.dropFirst() {
            rect = rect.union(CGRect(origin: p, size: .zero))
        }
        let scale = pdfView?.scaleFactor ?? 1
        let pad = StrokeGeometry.width(forPressure: 1, baseWidth: toolState.baseWidth, tool: toolState.tool) * scale + 4
        return rect.insetBy(dx: -pad, dy: -pad)
    }

    // MARK: - Zoom (pinch)

    override func magnify(with event: NSEvent) {
        guard let pdfView else { return }
        let newScale = pdfView.scaleFactor * (1.0 + event.magnification)
        pdfView.scaleFactor = min(max(newScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }

    // MARK: - Eraser (stroke-level)

    private func erase(at viewPoint: CGPoint, page: PDFPage, pageIndex: Int) {
        let pagePoint = viewToPage(viewPoint, page: page)
        // ~8 screen points of tolerance, expressed in page space.
        let tolerance = 8.0 / max(pdfView?.scaleFactor ?? 1, 0.01)
        while let hit = store.hitTest(point: pagePoint, pageIndex: pageIndex, tolerance: tolerance) {
            performRemove(strokeID: hit.id, pageIndex: pageIndex, actionName: "Erase Stroke")
        }
    }

    // MARK: - Mutations with undo

    func performAdd(_ stroke: Stroke, actionName: String = "Draw Stroke") {
        store.add(stroke)
        undoManager?.registerUndo(withTarget: self) { target in
            target.performRemove(strokeID: stroke.id, pageIndex: stroke.pageIndex, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    func performRemove(strokeID: UUID, pageIndex: Int, actionName: String) {
        guard let index = store.index(of: strokeID, pageIndex: pageIndex),
              let stroke = store.remove(id: strokeID, pageIndex: pageIndex) else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            target.performInsert(stroke, at: index, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    func performInsert(_ stroke: Stroke, at index: Int, actionName: String) {
        store.insert(stroke, at: index)
        undoManager?.registerUndo(withTarget: self) { target in
            target.performRemove(strokeID: stroke.id, pageIndex: stroke.pageIndex, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Proximity (eraser flip)

    private func handleProximity(_ event: NSEvent) {
        if event.isEnteringProximity {
            stylusIsEraserEnd = (event.pointingDeviceType == .eraser)
            NSLog("PDFInk: stylus entered proximity, device=%@",
                  stylusIsEraserEnd ? "eraser-end" : "pen-tip")
            toolState.stylusEnteredProximity(isEraserEnd: stylusIsEraserEnd)
        } else {
            NSLog("PDFInk: stylus left proximity")
        }
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let document = pdfView.document,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        for page in pdfView.visiblePages {
            let pageIndex = document.index(for: page)
            let pageRect = pageRectInView(for: page)
            guard pageRect.intersects(dirtyRect) else { continue }

            // Committed strokes: blit the per-page bitmap cache.
            if !store.strokes(onPage: pageIndex).isEmpty,
               let cache = cache(forPage: pageIndex, page: page),
               let image = cache.image {
                ctx.saveGState()
                ctx.clip(to: pageRect)
                ctx.draw(image, in: pageRect)
                ctx.restoreGState()
            }

            // Live stroke on top (vector, clipped to the dirty region).
            if pageIndex == activePageIndex, !activeSamples.isEmpty {
                ctx.saveGState()
                ctx.clip(to: pageRect.intersection(dirtyRect))
                ctx.concatenate(pageToViewTransform(for: page))
                let live = Stroke(tool: stylusIsEraserEnd ? .pen : toolState.tool,
                                  color: toolState.color,
                                  baseWidth: toolState.baseWidth,
                                  pageIndex: pageIndex,
                                  samples: activeSamples)
                StrokeRenderer.draw(live, in: ctx)
                ctx.restoreGState()
            }
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        switch toolState.tool {
        case .eraser: cursor = .disappearingItem
        case .lasso: cursor = .pointingHand
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }
}
