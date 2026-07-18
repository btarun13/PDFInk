import AppKit
import AVFoundation
import PDFKit
import PDFInkCore

/// Records a choreographed product demo straight to an H.264 MP4 —
/// `PDFInk demo.pdf --demo out.mp4`. Frames are composed in-app (no
/// screen-recording permission needed) and fed to AVAssetWriter while
/// synthesized tablet events drive the canvas in real time.
final class DemoDirector {

    private struct Step {
        var duration: Double
        var onBegin: (() -> Void)?
        /// progress in 0...1 within the step
        var onTick: ((Double) -> Void)?
        var onEnd: (() -> Void)?
    }

    private let controller: MainWindowController
    private let outURL: URL
    private let fps: Double = 15

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelSize = CGSize.zero

    private var steps: [Step] = []
    private var stepIndex = -1
    private var stepElapsed = 0.0
    private var frameIndex: Int64 = 0
    private var timer: Timer?

    /// Stylus indicator position (window coords) while a stroke animates.
    private var penPoint: CGPoint?
    private var card: (title: String, subtitle: String)?

    // Active animated stroke state
    private var strokePoints: [CGPoint] = []
    private var strokePressures: [CGFloat] = []
    private var strokeDelivered = 0

    init(controller: MainWindowController, outURL: URL) {
        self.controller = controller
        self.outURL = outURL
    }

    // MARK: - Script

    func start() {
        guard let window = controller.window else { return }
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.center()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            controller.discardDraftAndInk() // no leftovers from earlier runs
            // The resize/refit drifts the scroll position; pin to page top.
            scroll(toPageY: WhiteboardTemplate.pageSize.height)
            buildScript()
            guard beginWriting() else {
                NSLog("PDFInk[demo]: could not start AVAssetWriter")
                NSApp.terminate(nil)
                return
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    private func buildScript() {
        let c = controller

        // Window coords for targets in the demo document (1280x720 content,
        // page auto-fit; these were tuned against the composed layout).
        // Chart "Sep" bar top ≈ page (560, 620) area; title line ≈ y 640.

        addCard(duration: 2.0, title: "PDFInk", subtitle: "Handwritten PDF markup for Mac, built for Wacom pens")
        addWait(0.8)

        // 1. Highlight the recurring question (yellow highlighter).
        addStep(Step(duration: 0.01, onBegin: {
            c.toolState.tool = .highlighter
            c.toolState.color = ToolState.presetColors[4].color
        }))
        addAnimatedStroke(duration: 1.1, points: Self.line(from: CGPoint(x: 104, y: 488),
                                                           to: CGPoint(x: 468, y: 488), samples: 30),
                          pressures: Array(repeating: 0.6, count: 30))
        addWait(0.6)

        // 2. Circle Multivac's answer (red pen).
        addStep(Step(duration: 0.01, onBegin: {
            c.toolState.tool = .pen
            c.toolState.color = ToolState.presetColors[2].color
            c.toolState.baseWidth = 2
        }))
        addAnimatedStroke(duration: 1.3, points: Self.ellipse(center: CGPoint(x: 264, y: 437),
                                                              rx: 182, ry: 15, samples: 52),
                          pressures: Self.rampUpDown(52))
        addWait(0.7)

        // 3. Scroll down to the margin-notes line.
        addScroll(duration: 1.3, fromPageY: WhiteboardTemplate.pageSize.height, toPageY: 300)
        addWait(0.4)

        // 4. Scribble a margin note with pressure (blue pen).
        addStep(Step(duration: 0.01, onBegin: {
            c.toolState.tool = .pen
            c.toolState.color = ToolState.presetColors[1].color
        }))
        addAnimatedStroke(duration: 1.4, points: Self.signature(origin: CGPoint(x: 165, y: 152)),
                          pressures: Self.wave(count: 60))
        addWait(0.6)

        // 5. Zoom in on the note and back — strokes stay registered.
        addZoom(duration: 1.2, from: nil, to: 2.6)
        addWait(0.8)
        addZoom(duration: 1.0, from: 2.6, to: nil)
        addWait(0.4)

        // 6. Erase the note (stroke-level), then undo brings it back.
        addStep(Step(duration: 0.01, onBegin: { c.toolState.tool = .eraser }))
        addEraseTap(at: CGPoint(x: 240, y: 158), duration: 0.5)
        addWait(0.7)
        addStep(Step(duration: 0.01, onBegin: { c.window?.undoManager?.undo() }))
        addWait(0.8)

        // 7. Whiteboard finale: handwrite the story's famous last line.
        addStep(Step(duration: 0.01, onBegin: {
            c.newWhiteboard(template: .blank)
            c.toolState.tool = .pen
            c.toolState.color = ToolState.presetColors[0].color // black ink
            c.toolState.baseWidth = 4
        }))
        addWait(0.7)
        addHandwriting("And AC said,", baselineY: 470, scale: 4.2, secondsPerStroke: 0.13)
        addWait(0.3)
        addHandwriting("\"LET THERE BE LIGHT!\"", baselineY: 340, scale: 4.2, secondsPerStroke: 0.11)
        addWait(0.5)
        // Underline flourish in red.
        addStep(Step(duration: 0.01, onBegin: {
            c.toolState.color = ToolState.presetColors[2].color
            c.toolState.baseWidth = 2
        }))
        addAnimatedStroke(duration: 0.8, points: (0..<30).map { i in
            let t = CGFloat(i) / 29.0
            return CGPoint(x: 300 + t * 680, y: 296 + sin(t * .pi * 2) * 7)
        }, pressures: Self.rampUpDown(30), pageSpace: false)
        addWait(1.4)

        addCard(duration: 2.8, title: "PDFInk",
                subtitle: "Pressure ink · highlighter · eraser-flip · whiteboards\ngithub.com/btarun13/PDFInk")

        addStep(Step(duration: 0.01, onBegin: { [weak self] in self?.finish() }))
    }

    // MARK: - Step builders

    private func addStep(_ step: Step) { steps.append(step) }

    private func addWait(_ duration: Double) { steps.append(Step(duration: duration)) }

    private func addCard(duration: Double, title: String, subtitle: String) {
        steps.append(Step(duration: duration,
                          onBegin: { [weak self] in self?.card = (title, subtitle) },
                          onEnd: { [weak self] in self?.card = nil }))
    }

    /// Points are in PDF page-0 coordinates when `pageSpace` (resolved to
    /// window coordinates at delivery time, so scroll/zoom steps in between
    /// don't invalidate them); window coordinates otherwise.
    private func addAnimatedStroke(duration: Double, points: [CGPoint], pressures: [CGFloat],
                                   pageSpace: Bool = true) {
        steps.append(Step(
            duration: duration,
            onBegin: { [weak self] in
                guard let self else { return }
                self.strokePoints = points
                self.strokePressures = pressures
                self.strokeDelivered = 0
                if let first = points.first {
                    let p = pageSpace ? self.pagePoint(first) : first
                    self.deliver(.leftMouseDown, at: p, pressure: pressures.first ?? 0.5)
                    self.strokeDelivered = 1
                    self.penPoint = p
                }
            },
            onTick: { [weak self] progress in
                guard let self else { return }
                let target = max(1, Int(Double(self.strokePoints.count) * progress))
                while self.strokeDelivered < min(target, self.strokePoints.count) {
                    let i = self.strokeDelivered
                    let p = pageSpace ? self.pagePoint(self.strokePoints[i]) : self.strokePoints[i]
                    self.deliver(.leftMouseDragged, at: p,
                                 pressure: self.strokePressures[min(i, self.strokePressures.count - 1)])
                    self.penPoint = p
                    self.strokeDelivered += 1
                }
            },
            onEnd: { [weak self] in
                guard let self, let last = self.strokePoints.last else { return }
                let p = pageSpace ? self.pagePoint(last) : last
                self.deliver(.leftMouseUp, at: p, pressure: 0.3)
                self.penPoint = nil
            }))
    }

    private func addEraseTap(at pagePt: CGPoint, duration: Double) {
        steps.append(Step(duration: duration,
                          onBegin: { [weak self] in
                              guard let self else { return }
                              let p = self.pagePoint(pagePt)
                              self.penPoint = p
                              self.deliver(.leftMouseDown, at: p, pressure: 0.5)
                              self.deliver(.leftMouseUp, at: p, pressure: 0.5)
                          },
                          onEnd: { [weak self] in self?.penPoint = nil }))
    }

    /// Handwrites `text` on the whiteboard, stroke by stroke, centered
    /// horizontally in the canvas area (window coordinates).
    private func addHandwriting(_ text: String, baselineY: CGFloat, scale: CGFloat,
                                secondsPerStroke: Double) {
        let sidebarWidth: CGFloat = 158
        let canvasWidth: CGFloat = 1280 - sidebarWidth
        let textWidth = HandwritingFont.width(of: text, scale: scale)
        let originX = sidebarWidth + (canvasWidth - textWidth) / 2
        let strokes = HandwritingFont.strokes(for: text,
                                              origin: CGPoint(x: originX, y: baselineY),
                                              scale: scale)
        for stroke in strokes {
            let dense = Self.resample(stroke, maxSpacing: 5)
            addAnimatedStroke(duration: max(secondsPerStroke, Double(dense.count) / 60.0),
                              points: dense,
                              pressures: Self.wave(count: dense.count),
                              pageSpace: false)
        }
    }

    /// Densifies a polyline so live drawing animates smoothly.
    static func resample(_ points: [CGPoint], maxSpacing: CGFloat) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var out: [CGPoint] = [points[0]]
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let dist = hypot(b.x - a.x, b.y - a.y)
            let segments = max(1, Int(dist / maxSpacing))
            for s in 1...segments {
                let t = CGFloat(s) / CGFloat(segments)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return out
    }

    /// Smoothly scrolls so that page-y `toPageY` sits at the top of the view.
    private func addScroll(duration: Double, fromPageY: CGFloat, toPageY: CGFloat) {
        let controller = controller
        steps.append(Step(duration: duration, onTick: { progress in
            let eased = 0.5 - 0.5 * cos(progress * .pi)
            let y = fromPageY + (toPageY - fromPageY) * eased
            guard let page = controller.pdfView.document?.page(at: 0) else { return }
            controller.pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: y)))
        }))
    }

    private func scroll(toPageY y: CGFloat) {
        guard let page = controller.pdfView.document?.page(at: 0) else { return }
        controller.pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: y)))
    }

    private func addZoom(duration: Double, from: CGFloat?, to: CGFloat?) {
        let controller = controller
        var startScale: CGFloat = 1
        var endScale: CGFloat = 1
        steps.append(Step(
            duration: duration,
            onBegin: {
                startScale = from ?? controller.pdfView.scaleFactor
                if let to {
                    endScale = to
                } else {
                    // Back to fit-width: PDFView reports it via scaleFactorForSizeToFit.
                    endScale = controller.pdfView.scaleFactorForSizeToFit
                }
            },
            onTick: { progress in
                let eased = 0.5 - 0.5 * cos(progress * .pi) // ease in-out
                controller.pdfView.scaleFactor = startScale + (endScale - startScale) * eased
            }))
    }

    // MARK: - Event delivery (tablet-flavored)

    private func deliver(_ type: CGEventType, at windowPoint: CGPoint, pressure: CGFloat) {
        guard let canvas = controller.canvas, let window = controller.window else { return }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let globalPoint = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: globalPoint, mouseButton: .left) else { return }
        cg.setIntegerValueField(.mouseEventSubtype, value: 1)
        cg.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
        cg.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
        guard let ns = NSEvent(cgEvent: cg) else { return }
        if ProcessInfo.processInfo.environment["PDFINK_DEMO_DEBUG"] != nil, type == .leftMouseDown {
            NSLog("PDFInk[demo]: deliver windowPt=%@ appkitScreen=%@ cgGlobal=%@ nsLocation=%@ nsWindow=%d",
                  NSStringFromPoint(windowPoint), NSStringFromPoint(screenPoint),
                  NSStringFromPoint(globalPoint), NSStringFromPoint(ns.locationInWindow),
                  ns.window == nil ? 0 : 1)
        }
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: ns)
        case .leftMouseDragged: canvas.mouseDragged(with: ns)
        case .leftMouseUp: canvas.mouseUp(with: ns)
        default: break
        }
    }

    /// Window point for a location in page-0 coordinates, using the CURRENT
    /// scroll/zoom state (call at delivery time, not script-build time).
    private func pagePoint(_ p: CGPoint) -> CGPoint {
        guard let canvas = controller.canvas,
              let page = controller.pdfView.document?.page(at: 0) else { return p }
        let inPDFView = controller.pdfView.convert(p, from: page)
        let inCanvas = canvas.convert(inPDFView, from: controller.pdfView)
        return canvas.convert(inCanvas, to: nil)
    }

    // MARK: - Timeline pump

    private func tick() {
        if stepIndex < 0 {
            advanceStep()
        }
        stepElapsed += 1.0 / fps
        while stepIndex < steps.count {
            let step = steps[stepIndex]
            if stepElapsed >= step.duration {
                step.onTick?(1.0)
                step.onEnd?()
                stepElapsed -= step.duration
                advanceStep()
                if stepIndex >= steps.count { return }
                continue
            }
            step.onTick?(stepElapsed / step.duration)
            break
        }
        captureFrame()
    }

    private func advanceStep() {
        stepIndex += 1
        if stepIndex < steps.count {
            steps[stepIndex].onBegin?()
        }
    }

    // MARK: - Encoding

    private func beginWriting() -> Bool {
        guard let probe = controller.composeWindowImage() else { return false }
        pixelSize = CGSize(width: probe.width, height: probe.height)
        try? FileManager.default.removeItem(at: outURL)
        guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else { return false }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 9_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(pixelSize.width),
                kCVPixelBufferHeightKey as String: Int(pixelSize.height),
            ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        NSLog("PDFInk[demo]: recording %dx%d @ %.0f fps to %@",
              Int(pixelSize.width), Int(pixelSize.height), fps, outURL.path)
        return true
    }

    private func captureFrame() {
        guard let adaptor, let input, input.isReadyForMoreMediaData else { return }
        let image: CGImage?
        if let card {
            image = renderCard(title: card.title, subtitle: card.subtitle)
        } else if let composed = controller.composeWindowImage() {
            image = annotateWithPen(composed)
        } else {
            image = nil
        }
        guard let image, let buffer = pixelBuffer(from: image, pool: adaptor.pixelBufferPool) else { return }
        let time = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        adaptor.append(buffer, withPresentationTime: time)
        frameIndex += 1
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        guard let writer, let input else { NSApp.terminate(nil); return }
        input.markAsFinished()
        writer.finishWriting {
            NSLog("PDFInk[demo]: wrote %@ (%lld frames, %.1fs)",
                  self.outURL.path, self.frameIndex, Double(self.frameIndex) / self.fps)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Frame composition helpers

    /// Draws the stylus indicator dot over the composed frame.
    private func annotateWithPen(_ image: CGImage) -> CGImage {
        guard let penPoint, let window = controller.window,
              let contentView = window.contentView,
              let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let inContent = contentView.convert(penPoint, from: nil)
        let scale = CGFloat(image.width) / contentView.bounds.width
        let p = CGPoint(x: inContent.x * scale, y: inContent.y * scale)
        let r: CGFloat = 7 * scale
        let color = controller.toolState.color
        ctx.setFillColor(CGColor(red: color.red, green: color.green, blue: color.blue, alpha: 0.9))
        ctx.fillEllipse(in: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1.5 * scale)
        ctx.strokeEllipse(in: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r))
        return ctx.makeImage() ?? image
    }

    private func renderCard(title: String, subtitle: String) -> CGImage? {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let scale = CGFloat(w) / 1280.0

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 88 * scale, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26 * scale, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1),
        ]
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        let titleSize = titleStr.size()
        titleStr.draw(at: NSPoint(x: (CGFloat(w) - titleSize.width) / 2,
                                  y: CGFloat(h) * 0.52))

        var subY = CGFloat(h) * 0.52 - 56 * scale
        for line in subtitle.components(separatedBy: "\n") {
            let subStr = NSAttributedString(string: line, attributes: subAttrs)
            let subSize = subStr.size()
            subStr.draw(at: NSPoint(x: (CGFloat(w) - subSize.width) / 2, y: subY))
            subY -= 38 * scale
        }
        // Accent ink swoosh under the title.
        ctx.setStrokeColor(CGColor(red: 0.95, green: 0.35, blue: 0.30, alpha: 1))
        ctx.setLineWidth(6 * scale)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: CGFloat(w) * 0.40, y: CGFloat(h) * 0.49))
        ctx.addCurve(to: CGPoint(x: CGFloat(w) * 0.60, y: CGFloat(h) * 0.49),
                     control1: CGPoint(x: CGFloat(w) * 0.47, y: CGFloat(h) * 0.465),
                     control2: CGPoint(x: CGFloat(w) * 0.53, y: CGFloat(h) * 0.515))
        ctx.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32ARGB,
                                nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: image.width, height: image.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    // MARK: - Geometry generators (window/page coordinates)

    static func line(from a: CGPoint, to b: CGPoint, samples: Int) -> [CGPoint] {
        (0..<samples).map { i in
            let t = CGFloat(i) / CGFloat(samples - 1)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    static func polyline(_ vertices: [CGPoint], samplesPerSegment: Int) -> [CGPoint] {
        guard vertices.count > 1 else { return vertices }
        var out: [CGPoint] = []
        for i in 0..<(vertices.count - 1) {
            out += line(from: vertices[i], to: vertices[i + 1], samples: samplesPerSegment)
        }
        return out
    }

    static func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, samples: Int) -> [CGPoint] {
        (0...samples).map { i in
            let t = CGFloat(i) / CGFloat(samples) * 2 * .pi - .pi / 2
            return CGPoint(x: center.x + cos(t) * rx, y: center.y + sin(t) * ry)
        }
    }

    static func curve(from a: CGPoint, to b: CGPoint, samples: Int) -> [CGPoint] {
        (0..<samples).map { i in
            let t = CGFloat(i) / CGFloat(samples - 1)
            let eased = t * t // accelerating growth curve
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * eased)
        }
    }

    /// A flowing signature-like scribble.
    static func signature(origin: CGPoint) -> [CGPoint] {
        (0..<60).map { i in
            let t = CGFloat(i) / 59.0
            let x = origin.x + t * 150
            let y = origin.y + sin(t * .pi * 5) * 14 * (1 - t * 0.4) + t * 8
            return CGPoint(x: x, y: y)
        }
    }

    static func rampUp(_ count: Int) -> [CGFloat] {
        (0..<count).map { CGFloat($0) / CGFloat(count - 1) * 0.8 + 0.2 }
    }

    static func rampUpDown(_ count: Int) -> [CGFloat] {
        (0..<count).map { sin(CGFloat($0) / CGFloat(count - 1) * .pi) * 0.7 + 0.3 }
    }

    static func wave(count: Int) -> [CGFloat] {
        (0..<count).map { 0.35 + 0.55 * abs(sin(CGFloat($0) / 6.0)) }
    }
}
