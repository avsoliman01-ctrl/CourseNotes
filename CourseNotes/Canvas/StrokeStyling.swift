import PencilKit
import UIKit

enum StrokeLineStyle: String, CaseIterable, Identifiable {
    case solid, dashed, dotted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        }
    }
}

enum FillStyle: String, CaseIterable, Identifiable {
    /// The chosen color at full strength.
    case solid
    /// A pale tint of the chosen color, so outlines and writing on top stay easy to read.
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: "Solid Fill"
        case .light: "Light Fill"
        }
    }
}

/// Dashes, dots and fills for ink. PencilKit has none of these, so they are built from its
/// per-stroke clipping mask (`PKStroke.mask`, the same mechanism the pixel eraser uses):
///
/// - A dashed or dotted stroke is the original stroke with a mask that only lets the dashes or
///   dots through. Its path is untouched, so it moves, resizes and recolors like any stroke,
///   and can be made solid again.
/// - A fill is an extra stroke that sweeps back and forth across a shape, clipped to the shape's
///   outline and placed beneath all other ink.
///
/// Both are ordinary `PKDrawing` content: they save, reopen, erase, undo and export normally.
enum StrokeStyling {
    // MARK: Dashes and dots

    /// The stroke restyled, or nil if nothing changes.
    static func styled(_ stroke: PKStroke, as style: StrokeLineStyle) -> PKStroke? {
        var result = stroke
        switch style {
        case .solid:
            guard let mask = stroke.mask, isPatternMask(mask.cgPath, for: stroke) else { return nil }
            result.mask = nil
        case .dashed, .dotted:
            guard let pattern = patternMask(for: stroke, style: style) else { return nil }
            if let existing = stroke.mask, !isPatternMask(existing.cgPath, for: stroke) {
                // Keep gaps left by the pixel eraser: ink shows only where both masks allow.
                result.mask = UIBezierPath(cgPath: existing.cgPath.intersection(pattern))
            } else {
                result.mask = UIBezierPath(cgPath: pattern)
            }
        }
        return result
    }

    /// Union of small disks along the stroke, in the stroke's own coordinates (so the pattern
    /// follows the stroke when it is later moved or resized through its transform).
    private static func patternMask(for stroke: PKStroke, style: StrokeLineStyle) -> CGPath? {
        let width = strokeWidth(stroke)
        let disks = CGMutablePath()

        switch style {
        case .solid:
            return nil
        case .dotted:
            // A disk a little wider than the line clips it to a round dot.
            let radius = width * 0.55
            let spacing = width * 2.2 + 3
            for point in stroke.path.interpolatedPoints(by: .distance(spacing)) {
                addDisk(to: disks, at: point.location, radius: radius)
            }
        case .dashed:
            // Disks reach `radius` past their centers, so they are only placed far enough inside
            // each dash that the visible dash is exactly `dash` long.
            let radius = width
            let dash = width * 3 + 6
            let gap = width * 2 + 4
            let step = max(radius * 0.6, 0.75)
            var distance: CGFloat = 0
            for point in stroke.path.interpolatedPoints(by: .distance(step)) {
                let phase = distance.truncatingRemainder(dividingBy: dash + gap)
                if phase >= radius, phase <= dash - radius {
                    addDisk(to: disks, at: point.location, radius: radius)
                }
                distance += step
            }
        }
        guard !disks.isEmpty else { return nil }
        // Merge overlapping disks into clean outlines, so the mask means the same thing under
        // either fill rule.
        return disks.normalized()
    }

    /// A mask made by `patternMask`: many small pieces, none longer than one dash.
    /// Pixel-eraser masks are a few large regions, so they are never mistaken for a pattern.
    static func isPatternMask(_ mask: CGPath, for stroke: PKStroke) -> Bool {
        let width = strokeWidth(stroke)
        let limit = width * 5 + 10
        let pieces = mask.componentsSeparated()
        guard pieces.count >= 2 else { return false }
        return pieces.allSatisfy { piece in
            let box = piece.boundingBoxOfPath
            return box.width <= limit && box.height <= limit
        }
    }

    static func lineStyle(of stroke: PKStroke) -> StrokeLineStyle {
        guard let mask = stroke.mask, isPatternMask(mask.cgPath, for: stroke) else { return .solid }
        // Dots are round and no larger than about the line width; dashes are longer.
        let width = strokeWidth(stroke)
        let pieces = mask.cgPath.componentsSeparated()
        let longest = pieces.map { max($0.boundingBoxOfPath.width, $0.boundingBoxOfPath.height) }.max() ?? 0
        return longest <= width * 1.4 ? .dotted : .dashed
    }

    private static func strokeWidth(_ stroke: PKStroke) -> CGFloat {
        let widest = stroke.path.map { max($0.size.width, $0.size.height) }.max() ?? 2
        return max(widest, 1)
    }

    private static func addDisk(to path: CGMutablePath, at center: CGPoint, radius: CGFloat) {
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: Fills

    /// Width and row spacing of the sweep that paints a fill. Rows overlap generously, so no
    /// stripes show even if PencilKit draws the sweep a little narrower than asked.
    private static let fillSweepWidth: CGFloat = 16
    private static let fillRowSpacing: CGFloat = 6

    /// The area enclosed by a stroke whose ends meet (or nearly meet), in drawing coordinates.
    /// Nil for open strokes, tiny marks, and anything that isn't a fill already.
    static func closedRegion(of stroke: PKStroke) -> CGPath? {
        guard !isFill(stroke) else { return nil }
        let points = stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
        guard points.count >= 6, let first = points.first, let last = points.last else { return nil }

        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let diagonal = hypot(box.width, box.height)
        guard box.width >= 12, box.height >= 12 else { return nil }

        let gap = hypot(last.x - first.x, last.y - first.y)
        guard gap <= max(18, diagonal * 0.18) else { return nil }

        let outline = CGMutablePath()
        outline.addLines(between: points)
        outline.closeSubpath()
        let region = outline.normalized()
        return region.isEmpty ? nil : region
    }

    /// A stroke that paints `region` with `color`. It has an identity transform, so the mask is in
    /// drawing coordinates, just like the region.
    static func fillStroke(for region: CGPath, color: UIColor, style: FillStyle) -> PKStroke {
        let box = region.boundingBoxOfPath
        let width = fillSweepWidth
        let minX = box.minX - width
        let maxX = box.maxX + width
        let fillColor = style == .light ? tint(of: color) : color

        var points: [PKStrokePoint] = []
        var time: TimeInterval = 0
        var leftToRight = true
        var y = box.minY - width / 2
        while y <= box.maxY + width / 2 {
            for x in leftToRight ? [minX, maxX] : [maxX, minX] {
                // Each turn point is repeated so the stroke's spline passes straight through it.
                for _ in 0..<3 {
                    points.append(PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: time,
                                                size: CGSize(width: width, height: width), opacity: 1,
                                                force: 1, azimuth: 0, altitude: .pi / 2))
                    time += 0.004
                }
            }
            leftToRight.toggle()
            y += fillRowSpacing
        }

        return PKStroke(ink: PKInk(.monoline, color: fillColor),
                        strokePath: PKStrokePath(controlPoints: points, creationDate: Date()),
                        transform: .identity,
                        mask: UIBezierPath(cgPath: region))
    }

    /// Recognizes strokes made by `fillStroke`: masked sweeps whose turn points all sit exactly on
    /// the left or right edge of the sweep. Handwriting never has that shape.
    static func isFill(_ stroke: PKStroke) -> Bool {
        guard stroke.mask != nil, stroke.ink.inkType == .monoline else { return false }
        let locations = stroke.path.map(\.location)
        guard locations.count >= 6 else { return false }
        let minX = locations.map(\.x).min() ?? 0
        let maxX = locations.map(\.x).max() ?? 0
        guard maxX - minX > fillSweepWidth else { return false }
        return locations.allSatisfy { abs($0.x - minX) < 0.5 || abs($0.x - maxX) < 0.5 }
    }

    /// The painted area of a fill stroke, in drawing coordinates.
    static func fillBounds(_ stroke: PKStroke) -> CGRect {
        guard let mask = stroke.mask else { return .null }
        return mask.cgPath.boundingBoxOfPath.applying(stroke.transform)
    }

    /// True when `fill` paints `region` (a shape and its fill move and resize together, so their
    /// bounds stay in step).
    static func fill(_ fill: PKStroke, matches region: CGPath) -> Bool {
        let a = fillBounds(fill)
        let b = region.boundingBoxOfPath
        guard !a.isNull, !b.isNull else { return false }
        let tolerance = max(3, 0.04 * max(b.width, b.height))
        return abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// Whether a point in drawing coordinates is inside the painted area of a fill.
    static func fill(_ fill: PKStroke, contains point: CGPoint) -> Bool {
        guard let mask = fill.mask else { return false }
        return mask.contains(point.applying(fill.transform.inverted()))
    }

    /// The light-paper color mixed most of the way to white. On dark paper PencilKit adapts it
    /// into a dark tint of the same hue.
    private static func tint(of color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        let mix: CGFloat = 0.68
        return UIColor(red: r + (1 - r) * mix, green: g + (1 - g) * mix, blue: b + (1 - b) * mix, alpha: 1)
    }
}
