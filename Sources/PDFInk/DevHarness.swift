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
