import Foundation
import CoreGraphics

/// Model object holding all strokes, keyed by page index, in PDF page space.
/// Main-thread only. Undo/redo is wired by the app layer via the callbacks.
public final class StrokeStore: Codable {

    public private(set) var strokesByPage: [Int: [Stroke]] = [:]

    /// Bumped on every mutation; cheap change detection for autosave.
    public private(set) var generation: UInt64 = 0

    /// Called after any mutation (add/remove/restore) with the affected page index.
    public var onChange: ((Int) -> Void)?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case strokesByPage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // JSON dictionary keys are strings; store as [String: [Stroke]] on disk.
        let raw = try c.decode([String: [Stroke]].self, forKey: .strokesByPage)
        strokesByPage = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
            Int(k).map { ($0, v) }
        })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let raw = Dictionary(uniqueKeysWithValues: strokesByPage.map { (String($0.key), $0.value) })
        try c.encode(raw, forKey: .strokesByPage)
    }

    // MARK: - Queries

    public func strokes(onPage pageIndex: Int) -> [Stroke] {
        strokesByPage[pageIndex] ?? []
    }

    public var allStrokes: [Stroke] {
        strokesByPage.values.flatMap { $0 }
    }

    public var isEmpty: Bool {
        strokesByPage.values.allSatisfy(\.isEmpty)
    }

    /// Topmost stroke on a page within `tolerance` (page points) of `point`, if any.
    public func hitTest(point: CGPoint, pageIndex: Int, tolerance: CGFloat) -> Stroke? {
        for stroke in strokes(onPage: pageIndex).reversed() {
            guard stroke.pageBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { continue }
            if StrokeGeometry.stroke(stroke, contains: point, tolerance: tolerance) {
                return stroke
            }
        }
        return nil
    }

    // MARK: - Mutations

    public func add(_ stroke: Stroke) {
        strokesByPage[stroke.pageIndex, default: []].append(stroke)
        generation &+= 1
        onChange?(stroke.pageIndex)
    }

    @discardableResult
    public func remove(id: UUID, pageIndex: Int) -> Stroke? {
        guard var pageStrokes = strokesByPage[pageIndex],
              let idx = pageStrokes.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = pageStrokes.remove(at: idx)
        strokesByPage[pageIndex] = pageStrokes
        generation &+= 1
        onChange?(pageIndex)
        return removed
    }

    /// Reinserts a stroke removed by the eraser, preserving its z-order position.
    public func insert(_ stroke: Stroke, at index: Int) {
        var pageStrokes = strokesByPage[stroke.pageIndex] ?? []
        let clamped = min(max(index, 0), pageStrokes.count)
        pageStrokes.insert(stroke, at: clamped)
        strokesByPage[stroke.pageIndex] = pageStrokes
        generation &+= 1
        onChange?(stroke.pageIndex)
    }

    public func index(of id: UUID, pageIndex: Int) -> Int? {
        strokesByPage[pageIndex]?.firstIndex(where: { $0.id == id })
    }

    public func removeAll() {
        let pages = Array(strokesByPage.keys)
        strokesByPage = [:]
        generation &+= 1
        pages.forEach { onChange?($0) }
    }

    // MARK: - Persistence helpers

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func load(from data: Data) throws -> StrokeStore {
        try JSONDecoder().decode(StrokeStore.self, from: data)
    }
}
