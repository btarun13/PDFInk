import AppKit
import PDFKit
import PDFInkCore

/// Dev/testing harness: `PDFInk file.pdf --draw-test /tmp/prefix` synthesizes
/// mouse events into the drawing canvas (full input pipeline), then writes a
/// sequence of window snapshots:
///   <prefix>_a_drawn.png    pen + highlighter strokes at 100%
///   <prefix>_b_zoomed.png   same strokes at 2x zoom (registration check)
///   <prefix>_c_erased.png   after stroke-level erase of the highlighter
///   <prefix>_d_undone.png   after undo (highlighter restored)
/// Exits 0 when done.
enum DevHarness {

    static func run(controller: MainWindowController, prefix: String) {
        let steps: [(String, () -> Void)] = [
            ("draw pen stroke", {
                controller.toolState.tool = .pen
                controller.toolState.color = ToolState.presetColors[2].color // red
                simulateStroke(controller: controller,
                               fromWindow: CGPoint(x: 350, y: 650),
                               toWindow: CGPoint(x: 750, y: 450),
                               wiggle: 60)
            }),
            ("draw highlighter stroke", {
                controller.toolState.tool = .highlighter
                controller.toolState.color = ToolState.presetColors[4].color // yellow
                simulateStroke(controller: controller,
                               fromWindow: CGPoint(x: 320, y: 560),
                               toWindow: CGPoint(x: 820, y: 560),
                               wiggle: 0)
            }),
            ("snapshot a", { snapshot(controller, prefix, "a_drawn") }),
            ("zoom 2x", { controller.pdfView.scaleFactor = 2.0 }),
            ("snapshot b", { snapshot(controller, prefix, "b_zoomed") }),
            ("erase highlighter", {
                controller.toolState.tool = .eraser
                // Erase at the highlighter's page position, wherever it is on
                // screen at the current zoom — exercises view→page mapping.
                if let target = highlighterWindowPoint(controller) {
                    simulateStroke(controller: controller, fromWindow: target,
                                   toWindow: target, wiggle: 0)
                } else {
                    NSLog("PDFInk[devtest]: no highlighter stroke found to erase")
                }
            }),
            ("snapshot c", { snapshot(controller, prefix, "c_erased") }),
            ("undo erase", { controller.window?.undoManager?.undo() }),
            ("snapshot d", { snapshot(controller, prefix, "d_undone") }),
            ("report", {
                let counts = controller.store.strokesByPage.mapValues(\.count)
                NSLog("PDFInk[devtest]: final stroke counts per page: %@", "\(counts)")
                NSApp.terminate(nil)
            }),
        ]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(index) * 0.4) {
                NSLog("PDFInk[devtest]: step — %@", step.0)
                step.1()
            }
        }
    }

    private static func snapshot(_ controller: MainWindowController, _ prefix: String, _ name: String) {
        controller.writeWindowSnapshot(to: URL(fileURLWithPath: "\(prefix)_\(name).png"))
    }

    // MARK: - Tablet simulation (--pressure-test)

    /// Simulates Wacom-style input without hardware by building CGEvents with
    /// tablet subtype + pressure/tilt fields and delivering the wrapped
    /// NSEvents to the canvas. Verifies the event.subtype == .tabletPoint code
    /// path, pressure→width mapping, and tilt logging.
    static func runPressureTest(controller: MainWindowController, prefix: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            controller.toolState.tool = .pen
            controller.toolState.color = ToolState.presetColors[1].color // blue
            // Pressure ramps 0→1 along the stroke: width should swell 0.5→4pt.
            simulateTabletStroke(controller: controller,
                                 fromWindow: CGPoint(x: 300, y: 620),
                                 toWindow: CGPoint(x: 850, y: 620),
                                 pressure: { t in t })
            // Second stroke: pressure peaks mid-stroke (bulge shape).
            simulateTabletStroke(controller: controller,
                                 fromWindow: CGPoint(x: 300, y: 520),
                                 toWindow: CGPoint(x: 850, y: 520),
                                 pressure: { t in sin(t * .pi) })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            snapshot(controller, prefix, "pressure")
            let strokes = controller.store.strokes(onPage: 0)
            for (i, s) in strokes.enumerated() {
                let pressures = s.samples.map(\.pressure)
                NSLog("PDFInk[devtest]: stroke %d pressures min=%.2f max=%.2f count=%d",
                      i, pressures.min() ?? -1, pressures.max() ?? -1, s.samples.count)
            }
        }
        // Eraser-flip: post a synthesized proximity event (eraser end entering),
        // check the tool auto-switches, then flip back to the pen tip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            postProximityEvent(isEraser: true, entering: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            NSLog("PDFInk[devtest]: after eraser-end proximity, tool=%@", controller.toolState.tool.rawValue)
            postProximityEvent(isEraser: false, entering: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
            NSLog("PDFInk[devtest]: after pen-tip proximity, tool=%@", controller.toolState.tool.rawValue)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Persistence (--persist-test / --draft-test)

    /// Draws strokes, saves in place (ink annotations), exports flattened PDF.
    static func runPersistTest(controller: MainWindowController, prefix: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            controller.toolState.tool = .pen
            controller.toolState.color = ToolState.presetColors[2].color
            simulateTabletStroke(controller: controller,
                                 fromWindow: CGPoint(x: 320, y: 640),
                                 toWindow: CGPoint(x: 800, y: 500),
                                 pressure: { t in t })
            controller.toolState.tool = .highlighter
            controller.toolState.color = ToolState.presetColors[4].color
            simulateStroke(controller: controller,
                           fromWindow: CGPoint(x: 320, y: 560),
                           toWindow: CGPoint(x: 800, y: 560),
                           wiggle: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            controller.saveDocumentAction(nil)
            do {
                try controller.exportFlattened(to: URL(fileURLWithPath: "\(prefix)_flat.pdf"))
                NSLog("PDFInk[devtest]: flattened export done")
            } catch {
                NSLog("PDFInk[devtest]: flattened export FAILED: %@", error.localizedDescription)
            }
            NSApp.terminate(nil)
        }
    }

    /// Draws strokes and terminates WITHOUT saving — the autosave draft must
    /// restore them on next launch.
    static func runDraftTest(controller: MainWindowController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            controller.toolState.tool = .pen
            controller.toolState.color = ToolState.presetColors[5].color // purple
            simulateStroke(controller: controller,
                           fromWindow: CGPoint(x: 400, y: 400),
                           toWindow: CGPoint(x: 700, y: 250),
                           wiggle: 40)
            NSLog("PDFInk[devtest]: drew stroke, terminating without save")
            NSApp.terminate(nil)
        }
    }

    /// Builds a tabletProximity CGEvent and posts it through NSApp's event
    /// queue so local NSEvent monitors observe it, as with real hardware.
    private static func postProximityEvent(isEraser: Bool, entering: Bool) {
        guard let cg = CGEvent(source: nil) else { return }
        cg.type = .tabletProximity
        // NX_TABLET_POINTER_* encoding: pen=1, cursor=2, eraser=3.
        cg.setIntegerValueField(.tabletProximityEventPointerType, value: isEraser ? 3 : 1)
        cg.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        guard let ns = NSEvent(cgEvent: cg) else {
            NSLog("PDFInk[devtest]: could not wrap proximity CGEvent")
            return
        }
        NSLog("PDFInk[devtest]: posting proximity event type=%d entering=%d pointer=%@",
              ns.type.rawValue, entering ? 1 : 0, isEraser ? "eraser" : "pen")
        NSApp.postEvent(ns, atStart: false)
    }

    private static func simulateTabletStroke(controller: MainWindowController,
                                             fromWindow p0: CGPoint,
                                             toWindow p1: CGPoint,
                                             pressure: (CGFloat) -> CGFloat,
                                             steps: Int = 40) {
        guard let canvas = controller.canvas,
              let window = controller.window else { return }

        func tabletEvent(_ type: CGEventType, _ windowPoint: CGPoint, _ pressureValue: CGFloat) -> NSEvent? {
            // CGEvent locations are in global display coordinates (top-left origin).
            let screenPoint = window.convertPoint(toScreen: windowPoint)
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let globalPoint = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
            guard let cg = CGEvent(mouseEventSource: nil, mouseType: type,
                                   mouseCursorPosition: globalPoint, mouseButton: .left) else { return nil }
            cg.setIntegerValueField(.mouseEventSubtype, value: 1) // NSEvent.EventSubtype.tabletPoint
            cg.setDoubleValueField(.mouseEventPressure, value: Double(pressureValue))
            cg.setDoubleValueField(.tabletEventPointPressure, value: Double(pressureValue))
            cg.setDoubleValueField(.tabletEventTiltX, value: 0.25)
            cg.setDoubleValueField(.tabletEventTiltY, value: -0.10)
            guard let ns = NSEvent(cgEvent: cg) else { return nil }
            NSLog("PDFInk[devtest]: synthesized subtype=%d pressure=%.2f",
                  ns.subtype.rawValue, ns.pressure)
            return ns
        }

        if let down = tabletEvent(.leftMouseDown, p0, pressure(0)) { canvas.mouseDown(with: down) }
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t)
            if let drag = tabletEvent(.leftMouseDragged, point, pressure(t)) {
                canvas.mouseDragged(with: drag)
            }
        }
        if let up = tabletEvent(.leftMouseUp, p1, pressure(1)) { canvas.mouseUp(with: up) }
    }

    /// Window-space location of the first highlighter stroke's midpoint.
    private static func highlighterWindowPoint(_ controller: MainWindowController) -> CGPoint? {
        guard let canvas = controller.canvas,
              let document = controller.pdfView.document else { return nil }
        for (pageIndex, strokes) in controller.store.strokesByPage {
            guard let stroke = strokes.first(where: { $0.tool == .highlighter }),
                  let page = document.page(at: pageIndex) else { continue }
            let mid = stroke.samples[stroke.samples.count / 2].point
            let inPDFView = controller.pdfView.convert(mid, from: page)
            let inCanvas = canvas.convert(inPDFView, from: controller.pdfView)
            return canvas.convert(inCanvas, to: nil)
        }
        return nil
    }

    /// Delivers a synthesized mouseDown/drag.../mouseUp sequence to the canvas.
    /// Points are in window coordinates; a sine wiggle exercises smoothing.
    private static func simulateStroke(controller: MainWindowController,
                                       fromWindow p0: CGPoint,
                                       toWindow p1: CGPoint,
                                       wiggle: CGFloat,
                                       steps: Int = 24) {
        guard let canvas = controller.canvas,
              let windowNumber = controller.window?.windowNumber else { return }

        func event(_ type: NSEvent.EventType, _ location: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1.0)
        }

        if let down = event(.leftMouseDown, p0) { canvas.mouseDown(with: down) }
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            var point = CGPoint(x: p0.x + (p1.x - p0.x) * t,
                                y: p0.y + (p1.y - p0.y) * t)
            point.y += sin(t * .pi * 2) * wiggle
            if let drag = event(.leftMouseDragged, point) { canvas.mouseDragged(with: drag) }
        }
        if let up = event(.leftMouseUp, p1) { canvas.mouseUp(with: up) }
    }
}
