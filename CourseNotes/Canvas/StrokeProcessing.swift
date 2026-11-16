import PencilKit
import UIKit

enum SmoothingStrength: String, CaseIterable, Identifiable {
    case off, subtle, medium, strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .medium: "Medium"
        case .strong: "Strong"
        }
    }

    /// Smoothing passes over a stroke's control points.
    var passes: Int {
        switch self {
        case .off: 0
        case .subtle: 1
        case .medium: 2
        case .strong: 4
        }
    }
}

/// Handwriting enhancement: removes tremor and jaggedness from a stroke without redrawing it.
///
/// This is signal smoothing, not handwriting recognition. It never changes which strokes exist or
/// what they say. Each pass is a Taubin step (a smoothing step followed by a slightly stronger
/// inflating step), which filters out high-frequency wobble without shrinking loops and curves the
/// way plain averaging does. Stroke ends and sharp corners are pinned, and small marks (dots,
/// commas, decimal points, tick marks) are skipped entirely, so letterforms and math stay intact.
enum StrokeSmoother {
    /// Returns nil when the stroke should be left exactly as written.
    static func smoothed(_ stroke: PKStroke, strength: SmoothingStrength) -> PKStroke? {
        guard strength != .off else { return nil }
        let points = Array(stroke.path)
        let bounds = stroke.renderBounds
        guard points.count >= 6, max(bounds.width, bounds.height) >= 14 else { return nil }

        var locations = points.map(\.location)
        let pinned = pinnedPoints(in: locations)
        for _ in 0..<strength.passes {
            locations = relaxed(locations, pinned: pinned, factor: 0.5)
            locations = relaxed(locations, pinned: pinned, factor: -0.53)
        }
        // One gentle pass over the width evens out pressure flutter along the contour.
        let widths = relaxed(points.map(\.size.width), factor: 0.35)
        let heights = relaxed(points.map(\.size.height), factor: 0.35)

        let controlPoints = points.indices.map { index in
            let original = points[index]
            return PKStrokePoint(location: locations[index],
                                 timeOffset: original.timeOffset,
                                 size: CGSize(width: widths[index], height: heights[index]),
                                 opacity: original.opacity,
                                 force: original.force,
                                 azimuth: original.azimuth,
                                 altitude: original.altitude,
                                 secondaryScale: original.secondaryScale)
        }
        var result = stroke
        result.path = PKStrokePath(controlPoints: controlPoints, creationDate: stroke.path.creationDate)
        return result
    }

    /// Ends of the stroke and sharp direction changes (corners of a 4, a 7, a Σ, an arrowhead).
    private static func pinnedPoints(in locations: [CGPoint]) -> [Bool] {
        var pinned = [Bool](repeating: false, count: locations.count)
        pinned[0] = true
        pinned[locations.count - 1] = true
        guard locations.count > 4 else { return pinned }
        for index in 2..<(locations.count - 2) {
            let incoming = CGPoint(x: locations[index].x - locations[index - 2].x, y: locations[index].y - locations[index - 2].y)
            let outgoing = CGPoint(x: locations[index + 2].x - locations[index].x, y: locations[index + 2].y - locations[index].y)
            let lengths = hypot(incoming.x, incoming.y) * hypot(outgoing.x, outgoing.y)
            guard lengths > 0 else { continue }
            let cosine = (incoming.x * outgoing.x + incoming.y * outgoing.y) / lengths
            if cosine < 0.64 { pinned[index] = true }   // turns sharper than about 50°
        }
        return pinned
    }

    private static func relaxed(_ points: [CGPoint], pinned: [Bool], factor: CGFloat) -> [CGPoint] {
        var result = points
        for index in 1..<(points.count - 1) where !pinned[index] {
            let midpoint = CGPoint(x: (points[index - 1].x + points[index + 1].x) / 2,
                                   y: (points[index - 1].y + points[index + 1].y) / 2)
            result[index] = CGPoint(x: points[index].x + factor * (midpoint.x - points[index].x),
                                    y: points[index].y + factor * (midpoint.y - points[index].y))
        }
        return result
    }

    private static func relaxed(_ values: [CGFloat], factor: CGFloat) -> [CGFloat] {
        guard values.count > 2 else { return values }
        var result = values
        for index in 1..<(values.count - 1) {
            result[index] = values[index] + factor * ((values[index - 1] + values[index + 1]) / 2 - values[index])
        }
        return result
    }
}

/// Turns a recognized shape into real ink.
enum ShapeStrokeBuilder {
    /// A stroke that traces `shape` using the ink, typical width and pencil angle of the rough
    /// stroke it replaces. The result is ordinary `PKStroke` data: it saves, erases, lassos and
    /// exports like anything else on the page.
    static func stroke(for shape: RecognizedShape, replacing rough: PKStroke) -> PKStroke {
        let samples = Array(rough.path)
        let size = CGSize(width: median(samples.map(\.size.width)) ?? 3,
                          height: median(samples.map(\.size.height)) ?? 3)
        let opacity = median(samples.map(\.opacity)) ?? 1
        let reference = samples.isEmpty ? nil : samples[samples.count / 2]

        var controlPoints: [PKStrokePoint] = []
        var time: TimeInterval = 0
        for outlinePoint in shape.outline(spacing: 12) {
            // PKStrokePath is a uniform cubic B-spline: repeating a control point three times
            // makes the curve pass through it with a sharp corner instead of rounding it off.
            for _ in 0..<(outlinePoint.isCorner ? 3 : 1) {
                controlPoints.append(PKStrokePoint(location: outlinePoint.point,
                                                   timeOffset: time,
                                                   size: size,
                                                   opacity: opacity,
                                                   force: reference?.force ?? 1,
                                                   azimuth: reference?.azimuth ?? 0,
                                                   altitude: reference?.altitude ?? .pi / 2))
                time += 0.008
            }
        }

        var result = rough
        result.path = PKStrokePath(controlPoints: controlPoints, creationDate: rough.path.creationDate)
        result.transform = .identity
        result.mask = nil
        return result
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
