import Foundation
import CryptoKit
import PDFInkCore

/// Autosaves stroke drafts as JSON to Application Support every 30 seconds.
/// Drafts are keyed by a hash of the document path, so reopening a PDF after a
/// crash (or before an explicit save) restores unsaved ink.
final class AutosaveManager {

    static let interval: TimeInterval = 30

    private let store: StrokeStore
    private var timer: Timer?
    private var documentURL: URL?
    private var lastSavedGeneration: UInt64 = 0

    init(store: StrokeStore) {
        self.store = store
    }

    deinit { timer?.invalidate() }

    static func draftsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("PDFInk/Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func draftURL(forDocument url: URL) -> URL? {
        guard let dir = try? draftsDirectory() else { return nil }
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("\(name).pdfink.json")
    }

    // MARK: - Lifecycle

    func begin(documentURL: URL) {
        self.documentURL = documentURL
        lastSavedGeneration = store.generation
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.autosaveIfNeeded()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func autosaveIfNeeded() {
        guard store.generation != lastSavedGeneration else { return }
        saveNow()
    }

    func saveNow() {
        guard let documentURL, let draftURL = Self.draftURL(forDocument: documentURL) else { return }
        do {
            try store.jsonData().write(to: draftURL, options: .atomic)
            lastSavedGeneration = store.generation
            NSLog("PDFInk: autosaved draft (%d strokes) to %@", store.allStrokes.count, draftURL.lastPathComponent)
        } catch {
            NSLog("PDFInk: autosave FAILED: %@", error.localizedDescription)
        }
    }

    /// Removes the draft (call after a successful explicit save).
    func clearDraft() {
        guard let documentURL, let draftURL = Self.draftURL(forDocument: documentURL) else { return }
        try? FileManager.default.removeItem(at: draftURL)
        lastSavedGeneration = store.generation
    }

    static func loadDraft(forDocument url: URL) -> StrokeStore? {
        guard let draftURL = draftURL(forDocument: url),
              let data = try? Data(contentsOf: draftURL),
              let store = try? StrokeStore.load(from: data) else { return nil }
        return store
    }
}
