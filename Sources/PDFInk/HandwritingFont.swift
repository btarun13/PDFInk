import Foundation
import CoreGraphics

/// Minimal single-stroke letterforms for the demo's "handwritten" text.
/// Each glyph is a set of polylines on a 14-unit-tall grid (baseline y=0);
/// Catmull-Rom smoothing plus jitter in the canvas makes them read as marker
/// handwriting when replayed as strokes.
enum HandwritingFont {

    struct Glyph {
        let strokes: [[CGPoint]]
        let advance: CGFloat
    }

    static let glyphs: [Character: Glyph] = {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var g: [Character: Glyph] = [:]

        // Capitals (height 14)
        g["A"] = Glyph(strokes: [[p(0, 0), p(4.5, 14), p(9, 0)],
                                 [p(2.2, 5), p(6.8, 5)]], advance: 11)
        g["B"] = Glyph(strokes: [[p(0, 0), p(0, 14)],
                                 [p(0, 14), p(6, 14), p(8, 12.5), p(8, 9.5), p(6, 7.5), p(0, 7.5)],
                                 [p(0, 7.5), p(6.5, 7.5), p(8.7, 5.5), p(8.7, 2.2), p(6.5, 0), p(0, 0)]],
                       advance: 11)
        g["C"] = Glyph(strokes: [[p(9, 11.5), p(7.5, 13.3), p(4.5, 14), p(2, 13), p(0.5, 10),
                                  p(0.3, 7), p(0.5, 4), p(2, 1), p(4.5, 0), p(7.5, 0.7), p(9, 2.5)]],
                       advance: 11)
        g["D"] = Glyph(strokes: [[p(0, 0), p(0, 14)],
                                 [p(0, 14), p(5, 14), p(8, 12), p(9.3, 7), p(8, 2), p(5, 0), p(0, 0)]],
                       advance: 11.5)
        g["E"] = Glyph(strokes: [[p(9, 14), p(0, 14), p(0, 0), p(9, 0)],
                                 [p(0, 7.3), p(6.5, 7.3)]], advance: 10.5)
        g["G"] = Glyph(strokes: [[p(9, 11.5), p(7.5, 13.3), p(4.5, 14), p(2, 13), p(0.5, 10),
                                  p(0.3, 7), p(0.5, 4), p(2, 1), p(4.5, 0), p(7, 0), p(9, 1.5),
                                  p(9.3, 5.5), p(5.5, 5.5)]], advance: 11.5)
        g["H"] = Glyph(strokes: [[p(0, 0), p(0, 14)], [p(9, 0), p(9, 14)],
                                 [p(0, 7), p(9, 7)]], advance: 11.5)
        g["I"] = Glyph(strokes: [[p(1.5, 0), p(1.5, 14)]], advance: 4.5)
        g["L"] = Glyph(strokes: [[p(0, 14), p(0, 0), p(8.5, 0)]], advance: 10)
        g["N"] = Glyph(strokes: [[p(0, 0), p(0, 14)], [p(0, 14), p(9, 0)],
                                 [p(9, 0), p(9, 14)]], advance: 11.5)
        g["R"] = Glyph(strokes: [[p(0, 0), p(0, 14)],
                                 [p(0, 14), p(6, 14), p(8, 12.5), p(8, 9.6), p(6, 7.6), p(0, 7.6)],
                                 [p(3.5, 7.6), p(9, 0)]], advance: 11)
        g["S"] = Glyph(strokes: [[p(8.8, 11.8), p(7, 13.6), p(4, 14), p(1.5, 13), p(0.6, 11),
                                  p(1.5, 8.8), p(4, 7.6), p(6.5, 6.6), p(8.6, 5), p(9, 2.8),
                                  p(7.8, 0.8), p(5, 0), p(2, 0.4), p(0.3, 2)]], advance: 11)
        g["T"] = Glyph(strokes: [[p(0, 14), p(9, 14)], [p(4.5, 14), p(4.5, 0)]], advance: 10.5)

        // Lowercase (x-height 9)
        let bowl: [CGPoint] = [p(6.6, 7.2), p(4.5, 9), p(2.2, 8.4), p(0.7, 6.3), p(0.5, 3.5),
                               p(1.6, 1), p(3.8, 0), p(5.8, 1), p(6.6, 2.6)]
        g["a"] = Glyph(strokes: [bowl, [p(6.6, 9), p(6.6, 0)]], advance: 8.5)
        g["d"] = Glyph(strokes: [bowl, [p(6.6, 14), p(6.6, 0)]], advance: 8.5)
        g["i"] = Glyph(strokes: [[p(1.2, 9), p(1.2, 0)], [p(1.2, 12), p(1.2, 12.6)]], advance: 3.6)
        g["n"] = Glyph(strokes: [[p(0, 9), p(0, 0)],
                                 [p(0, 6.2), p(1.8, 8.4), p(4.2, 9), p(6, 7.4), p(6.3, 5), p(6.3, 0)]],
                       advance: 8.3)
        g["s"] = Glyph(strokes: [[p(6.3, 7.6), p(4.8, 8.9), p(2.4, 9), p(0.8, 7.8), p(1, 6.2),
                                  p(2.8, 5.2), p(4.8, 4.4), p(6.2, 3.2), p(6.3, 1.6), p(4.8, 0.2),
                                  p(2.4, 0), p(0.6, 1.2)]], advance: 8.2)

        // Punctuation
        g[","] = Glyph(strokes: [[p(1.4, 1.2), p(1.2, 0), p(0.3, -2.2)]], advance: 4.5)
        g["\""] = Glyph(strokes: [[p(0.4, 14), p(0.8, 10.8)], [p(3.2, 14), p(3.6, 10.8)]], advance: 6)
        g["!"] = Glyph(strokes: [[p(1, 14), p(1, 4.6)], [p(1, 1.6), p(1, 0.6)]], advance: 4)
        g[" "] = Glyph(strokes: [], advance: 5.5)
        return g
    }()

    /// Lays out `text` as a list of strokes (each a polyline) in the target
    /// coordinate space. `origin` is the baseline start point; y grows up.
    /// A little deterministic jitter keeps the letters from looking machined.
    static func strokes(for text: String, origin: CGPoint, scale: CGFloat,
                        jitter: CGFloat = 0.35) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var penX = origin.x
        var noiseIndex: CGFloat = 0
        for ch in text {
            guard let glyph = glyphs[ch] else { continue }
            for stroke in glyph.strokes {
                var points: [CGPoint] = []
                for pt in stroke {
                    noiseIndex += 1
                    let jx = sin(noiseIndex * 12.9898) * jitter * scale
                    let jy = cos(noiseIndex * 78.233) * jitter * scale
                    points.append(CGPoint(x: penX + pt.x * scale + jx,
                                          y: origin.y + pt.y * scale + jy))
                }
                result.append(points)
            }
            penX += (glyph.advance + 1.6) * scale
        }
        return result
    }

    /// Total advance width of `text` at `scale`, for centering.
    static func width(of text: String, scale: CGFloat) -> CGFloat {
        text.reduce(CGFloat(0)) { $0 + ((glyphs[$1]?.advance ?? 0) + 1.6) * scale }
    }
}
