import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    var mainWindowController: MainWindowController?
    var demoDirector: DemoDirector?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenuBar()

        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Support `PDFInk file.pdf` from the command line (dev convenience).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            controller.openPDF(at: URL(fileURLWithPath: path))
        }

        // Dev/testing hook: synthesizes strokes and writes snapshot sequence.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--draw-test"),
           CommandLine.arguments.count > flagIndex + 1 {
            DevHarness.run(controller: controller, prefix: CommandLine.arguments[flagIndex + 1])
        }

        // Dev/testing hook: simulated tablet events (subtype/pressure/tilt).
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--pressure-test"),
           CommandLine.arguments.count > flagIndex + 1 {
            DevHarness.runPressureTest(controller: controller, prefix: CommandLine.arguments[flagIndex + 1])
        }

        // Dev/testing hook: draw, save in place, export flattened.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--persist-test"),
           CommandLine.arguments.count > flagIndex + 1 {
            DevHarness.runPersistTest(controller: controller, prefix: CommandLine.arguments[flagIndex + 1])
        }

        // Dev/testing hook: draw, then quit without saving (draft autosave).
        if CommandLine.arguments.contains("--draft-test") {
            DevHarness.runDraftTest(controller: controller)
        }

        // Demo recorder: `PDFInk demo.pdf --demo out.mp4` writes a product
        // demo video (H.264) composed entirely in-app.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--demo"),
           CommandLine.arguments.count > flagIndex + 1 {
            let director = DemoDirector(controller: controller,
                                        outURL: URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1]))
            demoDirector = director
            director.start()
        }

        // Dev/testing hook: whiteboard create + add page + save.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--whiteboard-test"),
           CommandLine.arguments.count > flagIndex + 1 {
            DevHarness.runWhiteboardTest(controller: controller, prefix: CommandLine.arguments[flagIndex + 1])
        }

        // Dev/testing hook: `PDFInk file.pdf --snapshot out.png` renders the
        // window into a PNG (no screen-recording permission needed) and quits.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > flagIndex + 1 {
            let outPath = CommandLine.arguments[flagIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak controller] in
                controller?.logPageGeometry()
                controller?.writeWindowSnapshot(to: URL(fileURLWithPath: outPath))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Scripted demo runs are throwaway — don't leave a draft behind.
        guard demoDirector == nil else { return }
        mainWindowController?.persistDraftIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Finder / Dock / `open -a PDFInk file.pdf`
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        mainWindowController?.openPDF(at: url)
    }

    // MARK: - Menu bar

    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About PDFInk",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PDFInk",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        let newWhiteboardItem = NSMenuItem(title: "New Whiteboard", action: nil, keyEquivalent: "")
        let newWhiteboardMenu = NSMenu(title: "New Whiteboard")
        newWhiteboardMenu.addItem(withTitle: "Blank",
                                  action: #selector(MainWindowController.newBlankWhiteboardAction(_:)),
                                  keyEquivalent: "n")
        newWhiteboardMenu.addItem(withTitle: "Grid",
                                  action: #selector(MainWindowController.newGridWhiteboardAction(_:)),
                                  keyEquivalent: "")
        newWhiteboardMenu.addItem(withTitle: "Lined",
                                  action: #selector(MainWindowController.newLinedWhiteboardAction(_:)),
                                  keyEquivalent: "")
        newWhiteboardItem.submenu = newWhiteboardMenu
        fileMenu.addItem(newWhiteboardItem)

        let addPageItem = fileMenu.addItem(withTitle: "Add Page",
                                           action: #selector(MainWindowController.addPageAction(_:)),
                                           keyEquivalent: "n")
        addPageItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open…", action: #selector(MainWindowController.openDocumentAction(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(MainWindowController.saveDocumentAction(_:)), keyEquivalent: "s")
        let exportItem = fileMenu.addItem(withTitle: "Export Flattened PDF…",
                                          action: #selector(MainWindowController.exportFlattenedAction(_:)),
                                          keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit menu (undo/redo route through the responder chain)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(MainWindowController.zoomInAction(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(MainWindowController.zoomOutAction(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(MainWindowController.actualSizeAction(_:)), keyEquivalent: "0")

        // Tools menu
        let toolsMenuItem = NSMenuItem()
        mainMenu.addItem(toolsMenuItem)
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenuItem.submenu = toolsMenu
        toolsMenu.addItem(withTitle: "Pen", action: #selector(MainWindowController.selectPenAction(_:)), keyEquivalent: "1")
        toolsMenu.addItem(withTitle: "Highlighter", action: #selector(MainWindowController.selectHighlighterAction(_:)), keyEquivalent: "2")
        toolsMenu.addItem(withTitle: "Eraser", action: #selector(MainWindowController.selectEraserAction(_:)), keyEquivalent: "3")
        toolsMenu.addItem(withTitle: "Lasso Select (coming soon)", action: nil, keyEquivalent: "4")

        NSApp.mainMenu = mainMenu
    }
}
