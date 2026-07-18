import AppKit
import PDFKit
import PDFInkCore
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate {

    let pdfView = PDFView()
    let thumbnailView = PDFThumbnailView()
    private let dropContainer = DropContainerView()
    private let placeholderLabel = NSTextField(labelWithString: "Drop a PDF here or use File ▸ Open (⌘O)")

    let store = StrokeStore()
    let toolState = ToolState()
    private(set) var canvas: DrawingCanvasView?
    private lazy var autosave = AutosaveManager(store: store)
    /// Store generation at the last successful explicit save.
    private var savedGeneration: UInt64 = 0

    private var toolSegment: NSSegmentedControl?
    private var widthSegment: NSSegmentedControl?
    private var colorPopUp: NSPopUpButton?

    private(set) var fileURL: URL?
    /// Template used when this document was created as a whiteboard; Add Page
    /// appends a matching page (blank for opened PDFs).
    private(set) var whiteboardTemplate: WhiteboardTemplate?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "PDFInk"
        window.center()
        window.setFrameAutosaveName("PDFInkMainWindow")
        super.init(window: window)
        window.delegate = self
        setUpContentView()
        setUpToolbar()

        store.onChange = { [weak self] pageIndex in
            guard let self else { return }
            self.canvas?.storeDidChange(pageIndex: pageIndex)
            self.window?.isDocumentEdited = true
        }
        toolState.onChange = { [weak self] in
            self?.canvas?.toolStateDidChange()
            self?.syncToolbarSelection()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func setUpContentView() {
        guard let contentView = window?.contentView else { return }

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor

        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 120, height: 160)
        thumbnailView.backgroundColor = .underPageBackgroundColor

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(thumbnailView)
        splitView.addArrangedSubview(pdfView)
        thumbnailView.widthAnchor.constraint(equalToConstant: 150).isActive = true
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        dropContainer.onPDFDropped = { [weak self] url in
            self?.openPDF(at: url)
        }
        dropContainer.translatesAutoresizingMaskIntoConstraints = false
        splitView.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.font = .systemFont(ofSize: 16, weight: .medium)

        contentView.addSubview(dropContainer)
        dropContainer.addSubview(splitView)
        dropContainer.addSubview(placeholderLabel)

        // Drawing overlay sits on top of the PDFView, same frame, and maps all
        // input through PDFView's page geometry.
        let canvasView = DrawingCanvasView(pdfView: pdfView, store: store, toolState: toolState)
        pdfView.addSubview(canvasView)
        canvas = canvasView

        NSLayoutConstraint.activate([
            dropContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            dropContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dropContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dropContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: dropContainer.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: dropContainer.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: dropContainer.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: dropContainer.centerYAnchor),
        ])
    }

    // MARK: - Toolbar

    private enum ToolbarID {
        static let tools = NSToolbarItem.Identifier("pdfink.tools")
        static let color = NSToolbarItem.Identifier("pdfink.color")
        static let width = NSToolbarItem.Identifier("pdfink.width")
    }

    private func setUpToolbar() {
        let toolbar = NSToolbar(identifier: "PDFInkToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    fileprivate func makeToolsItem() -> NSToolbarItem {
        let segment = NSSegmentedControl(
            labels: ["✏️ Pen", "🖍 Highlight", "◻️ Erase", "◌ Lasso"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(toolSegmentChanged(_:)))
        segment.selectedSegment = 0
        toolSegment = segment
        let item = NSToolbarItem(itemIdentifier: ToolbarID.tools)
        item.label = "Tools"
        item.view = segment
        return item
    }

    fileprivate func makeColorItem() -> NSToolbarItem {
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 60, height: 24), pullsDown: false)
        for (index, preset) in ToolState.presetColors.enumerated() {
            let menuItem = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
            menuItem.image = Self.swatchImage(for: preset.color)
            menuItem.tag = index
            popUp.menu?.addItem(menuItem)
        }
        popUp.menu?.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: nil, keyEquivalent: "")
        custom.tag = -1
        popUp.menu?.addItem(custom)
        popUp.target = self
        popUp.action = #selector(colorChanged(_:))
        colorPopUp = popUp
        let item = NSToolbarItem(itemIdentifier: ToolbarID.color)
        item.label = "Color"
        item.view = popUp
        return item
    }

    fileprivate func makeWidthItem() -> NSToolbarItem {
        let segment = NSSegmentedControl(
            labels: ToolState.widthPresets.map(\.name),
            trackingMode: .selectOne,
            target: self,
            action: #selector(widthChanged(_:)))
        segment.selectedSegment = 1
        widthSegment = segment
        let item = NSToolbarItem(itemIdentifier: ToolbarID.width)
        item.label = "Width"
        item.view = segment
        return item
    }

    private static func swatchImage(for color: StrokeColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor(calibratedRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            path.fill()
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            return true
        }
    }

    private func syncToolbarSelection() {
        let toolIndex: Int
        switch toolState.tool {
        case .pen: toolIndex = 0
        case .highlighter: toolIndex = 1
        case .eraser: toolIndex = 2
        case .lasso: toolIndex = 3
        }
        toolSegment?.selectedSegment = toolIndex
    }

    @objc private func toolSegmentChanged(_ sender: NSSegmentedControl) {
        let tools: [Tool] = [.pen, .highlighter, .eraser, .lasso]
        guard (0..<tools.count).contains(sender.selectedSegment) else { return }
        toolState.tool = tools[sender.selectedSegment]
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        guard let selected = sender.selectedItem else { return }
        if selected.tag == -1 {
            let panel = NSColorPanel.shared
            panel.setTarget(self)
            panel.setAction(#selector(customColorPicked(_:)))
            panel.orderFront(nil)
        } else if (0..<ToolState.presetColors.count).contains(selected.tag) {
            toolState.color = ToolState.presetColors[selected.tag].color
        }
    }

    @objc private func customColorPicked(_ sender: NSColorPanel) {
        toolState.setColor(from: sender.color)
    }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        guard (0..<ToolState.widthPresets.count).contains(sender.selectedSegment) else { return }
        toolState.baseWidth = ToolState.widthPresets[sender.selectedSegment].width
    }

    // MARK: - Document handling

    func openPDF(at url: URL) {
        guard let document = PDFDocument(url: url) else {
            presentError(message: "Couldn't open PDF", info: url.path)
            return
        }
        autosave.saveNow() // preserve unsaved ink of the previous document
        fileURL = url
        whiteboardTemplate = nil // newWhiteboard(template:) restores it after

        // Reload editable strokes: an autosaved draft wins (it's newest);
        // otherwise recover strokes from PDFInk annotations saved in the file.
        store.removeAll()
        window?.undoManager?.removeAllActions()
        if let draft = AutosaveManager.loadDraft(forDocument: url), !draft.isEmpty {
            for stroke in draft.allStrokes { store.add(stroke) }
            NSLog("PDFInk: restored %d strokes from autosave draft", draft.allStrokes.count)
        } else {
            let recovered = AnnotationSerializer.extractStrokes(from: document)
            for stroke in recovered { store.add(stroke) }
            if !recovered.isEmpty {
                NSLog("PDFInk: recovered %d strokes from PDF annotations", recovered.count)
            }
        }
        // PDFInk-tagged annotations are re-editable via the store, so hide them
        // from the display copy — the canvas is the source of truth on screen.
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.userName == AnnotationSerializer.annotationTitle {
                page.removeAnnotation(annotation)
            }
        }

        pdfView.document = document
        pdfView.layoutDocumentView()
        if let firstPage = document.page(at: 0) {
            let top = CGPoint(x: 0, y: firstPage.bounds(for: pdfView.displayBox).maxY)
            pdfView.go(to: PDFDestination(page: firstPage, at: top))
        }
        placeholderLabel.isHidden = true
        savedGeneration = store.generation
        window?.isDocumentEdited = false
        autosave.begin(documentURL: url)
        window?.title = "PDFInk — \(url.lastPathComponent)"
        window?.representedURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        NSLog("PDFInk: opened \(url.lastPathComponent) with \(document.pageCount) pages")
    }

    func windowWillClose(_ notification: Notification) {
        persistDraftIfNeeded()
    }

    // MARK: - Whiteboards (notebook-style)

    static func whiteboardsDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("PDFInk Whiteboards", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a new whiteboard as a real PDF file (so save/autosave work
    /// immediately, notebook-style) and opens it.
    func newWhiteboard(template: WhiteboardTemplate) {
        do {
            let dir = try Self.whiteboardsDirectory()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            let stamp = formatter.string(from: Date())
            var url = dir.appendingPathComponent("Whiteboard \(stamp).pdf")
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("Whiteboard \(stamp) (\(counter)).pdf")
                counter += 1
            }
            try template.pdfData(pageCount: 1).write(to: url)
            openPDF(at: url) // clears whiteboardTemplate, so set it after
            whiteboardTemplate = template
            NSLog("PDFInk: created %@ whiteboard at %@", template.rawValue, url.path)
        } catch {
            presentError(message: "Couldn't create whiteboard", info: error.localizedDescription)
        }
    }

    /// Appends a page matching the whiteboard's template (blank for PDFs).
    @objc func addPageAction(_ sender: Any?) {
        guard let document = pdfView.document else { return }
        let template = whiteboardTemplate ?? .blank
        guard let page = template.makePage() else { return }
        document.insert(page, at: document.pageCount)
        pdfView.layoutDocumentView()
        window?.isDocumentEdited = true
        // Scroll to the new page so it's ready to draw on.
        if let newPage = document.page(at: document.pageCount - 1) {
            let top = CGPoint(x: 0, y: newPage.bounds(for: pdfView.displayBox).maxY)
            pdfView.go(to: PDFDestination(page: newPage, at: top))
        }
        NSLog("PDFInk: added %@ page, document now has %d pages",
              template.rawValue, document.pageCount)
        // Whiteboards persist structure immediately, notebook-style; for
        // opened PDFs the user decides when to write with Cmd+S.
        if whiteboardTemplate != nil {
            saveDocumentAction(nil)
        }
    }

    @objc func newBlankWhiteboardAction(_ sender: Any?) { newWhiteboard(template: .blank) }
    @objc func newGridWhiteboardAction(_ sender: Any?) { newWhiteboard(template: .grid) }
    @objc func newLinedWhiteboardAction(_ sender: Any?) { newWhiteboard(template: .lined) }

    /// Unsaved ink survives via the draft; explicit save clears it.
    func persistDraftIfNeeded() {
        if store.generation != savedGeneration {
            autosave.saveNow()
        }
    }

    /// Dev/testing: renders the window's content view into a PNG.
    func writeWindowSnapshot(to url: URL) {
        guard let contentView = window?.contentView else { return }
        NSLog("PDFInk: snapshot state: scale=%.2f currentPage=%@ visible=%d docView=%@",
              pdfView.scaleFactor,
              pdfView.currentPage.map { String(describing: pdfView.document?.index(for: $0)) } ?? "nil",
              pdfView.visiblePages.count,
              NSStringFromRect(pdfView.documentView?.frame ?? .zero))

        // PDFView draws through Metal-backed layers that cacheDisplay can't
        // capture, so compose the snapshot manually: the view hierarchy first
        // (chrome, sidebar, drawing overlay), then the visible PDF pages drawn
        // through the same page→view transforms the app uses. Any coordinate
        // bug shows up as misregistration between pages and ink.
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        contentView.cacheDisplay(in: bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / bounds.width
        guard let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)

        // Layer 1: PDF pages at their on-screen positions.
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(bounds)
        if pdfView.document != nil {
            for page in pdfView.visiblePages {
                let pageRectInContent = contentView.convert(
                    pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
                ctx.saveGState()
                // Convert to the CG context's bottom-left origin if needed.
                let flippedY = contentView.isFlipped
                    ? bounds.height - pageRectInContent.maxY
                    : pageRectInContent.minY
                ctx.translateBy(x: pageRectInContent.minX, y: flippedY)
                ctx.scaleBy(x: pageRectInContent.width / page.bounds(for: pdfView.displayBox).width,
                            y: pageRectInContent.height / page.bounds(for: pdfView.displayBox).height)
                ctx.setFillColor(.white)
                ctx.fill(page.bounds(for: pdfView.displayBox))
                page.draw(with: pdfView.displayBox, to: ctx)
                ctx.restoreGState()
            }
        }

        // Layer 2: the captured view hierarchy (sidebar, overlay ink, chrome)
        // composited on top, letting the PDF show through where views are clear.
        if let viewImage = rep.cgImage {
            ctx.saveGState()
            ctx.scaleBy(x: 1 / scale, y: 1 / scale)
            ctx.setBlendMode(.multiply) // white view backgrounds pass the pages through
            ctx.draw(viewImage, in: CGRect(x: 0, y: 0,
                                           width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
            ctx.restoreGState()
        }

        if let image = ctx.makeImage(),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            NSLog("PDFInk: snapshot written to %@", url.path)
        }
    }

    private func presentError(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Menu actions

    @objc func openDocumentAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openPDF(at: url)
        }
    }

    /// Cmd+S: writes strokes as ink annotations into the PDF in place.
    /// The annotations are applied to a copy so the display document (and the
    /// canvas as source of truth) stay annotation-free.
    @objc func saveDocumentAction(_ sender: Any?) {
        guard let document = pdfView.document, let url = fileURL else { return }
        guard let data = document.dataRepresentation(),
              let copy = PDFDocument(data: data) else {
            presentError(message: "Couldn't prepare document for saving", info: url.lastPathComponent)
            return
        }
        AnnotationSerializer.apply(store: store, to: copy)
        if copy.write(to: url) {
            savedGeneration = store.generation
            window?.isDocumentEdited = false
            autosave.clearDraft()
            NSLog("PDFInk: saved %d strokes as ink annotations to %@",
                  store.allStrokes.count, url.lastPathComponent)
        } else {
            presentError(message: "Couldn't save PDF", info: url.path)
        }
    }

    @objc func exportFlattenedAction(_ sender: Any?) {
        guard let document = pdfView.document, let url = fileURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (flattened).pdf"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let outURL = panel.url else { return }
            do {
                try FlattenedExporter.export(document: document, store: self.store, to: outURL)
                NSLog("PDFInk: exported flattened PDF to %@", outURL.path)
            } catch {
                self.presentError(message: "Export failed", info: error.localizedDescription)
            }
        }
    }

    /// Dev/testing: non-interactive flattened export.
    func exportFlattened(to outURL: URL) throws {
        guard let document = pdfView.document else { return }
        try FlattenedExporter.export(document: document, store: store, to: outURL)
    }

    @objc func zoomInAction(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOutAction(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func actualSizeAction(_ sender: Any?) { pdfView.scaleFactor = 1.0 }

    @objc func selectPenAction(_ sender: Any?) { toolState.tool = .pen }
    @objc func selectHighlighterAction(_ sender: Any?) { toolState.tool = .highlighter }
    @objc func selectEraserAction(_ sender: Any?) { toolState.tool = .eraser }

    @objc func undo(_ sender: Any?) { window?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { window?.undoManager?.redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return window?.undoManager?.canUndo ?? false
        case #selector(redo(_:)): return window?.undoManager?.canRedo ?? false
        default: return true
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        // Disable document-dependent menu items until a PDF is open.
        let docSelectors: Set<Selector> = [
            #selector(saveDocumentAction(_:)), #selector(exportFlattenedAction(_:)),
            #selector(zoomInAction(_:)), #selector(zoomOutAction(_:)), #selector(actualSizeAction(_:)),
            #selector(addPageAction(_:)),
        ]
        if let sel = aSelector, docSelectors.contains(sel), pdfView.document == nil {
            return false
        }
        return super.responds(to: aSelector)
    }
}

/// Container view accepting PDF file drags anywhere in the window.
final class DropContainerView: NSView {

    var onPDFDropped: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func pdfURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.pdf.identifier],
        ]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pdfURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = pdfURL(from: sender) else { return false }
        onPDFDropped?(url)
        return true
    }
}

extension MainWindowController {
    /// Dev: dump page placement geometry for snapshot debugging.
    func logPageGeometry() {
        guard let contentView = window?.contentView, let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let r = contentView.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
            NSLog("PDFInk: page %d rectInContent=%@", i, NSStringFromRect(r))
        }
        NSLog("PDFInk: contentView bounds=%@ flipped=%d", NSStringFromRect(contentView.bounds), contentView.isFlipped ? 1 : 0)
    }
}

extension MainWindowController {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.tools, .flexibleSpace, ToolbarID.color, ToolbarID.width]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.tools: return makeToolsItem()
        case ToolbarID.color: return makeColorItem()
        case ToolbarID.width: return makeWidthItem()
        default: return nil
        }
    }
}
