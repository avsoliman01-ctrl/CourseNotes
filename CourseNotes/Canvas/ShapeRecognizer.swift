import CoreGraphics
import Foundation

/// A clean geometric shape recovered from a rough stroke.
enum RecognizedShape: Equatable {
    case line(from: CGPoint, to: CGPoint)
    case ellipse(center: CGPoint, radii: CGSize, rotation: CGFloat)
    /// Closed shape with straight edges (triangle, rectangle, pentagon…).
    case polygon([CGPoint])
    /// Open run of straight segments (an "L", a "Z", an axis pair…).
    case polyline([CGPoint])

    struct OutlinePoint {
        var point: CGPoint
        /// Sharp corners are kept sharp when the outline becomes a stroke.
        var isCorner: Bool
    }

    var center: CGPoint {
        switch self {
        case .line(let start, let end):
            return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        case .ellipse(let center, _, _):
            return center
        case .polygon(let points), .polyline(let points):
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let count = CGFloat(max(points.count, 1))
            return CGPoint(x: sum.x / count, y: sum.y / count)
        }
    }

    /// Ordered points to stroke through, `spacing` apart along curves and long edges.
    func outline(spacing: CGFloat) -> [OutlinePoint] {
        switch self {
        case .line(let start, let end):
            return Self.edges(through: [start, end], spacing: spacing)
        case .polyline(let points):
            return Self.edges(through: points, spacing: spacing)
        case .polygon(let points):
            guard let first = points.first else { return [] }
            return Self.edges(through: points + [first], spacing: spacing)
        case .ellipse(let center, let radii, let rotation):
            let circumference = 2 * CGFloat.pi * sqrt((radii.width * radii.width + radii.height * radii.height) / 2)
            let count = max(24, Int(circumference / max(spacing, 1)))
            // Run slightly past a full turn so the ends of the stroke overlap and close cleanly.
            return (0...(count + 2)).map { step in
                let angle = CGFloat(step) / CGFloat(count) * 2 * .pi
                let local = CGPoint(x: cos(angle) * radii.width, y: sin(angle) * radii.height)
                return OutlinePoint(point: CGPoint(x: center.x + local.x * cos(rotation) - local.y * sin(rotation),
                                                   y: center.y + local.x * sin(rotation) + local.y * cos(rotation)),
                                    isCorner: false)
            }
        }
    }

    /// While the pencil is still held after recognition, it keeps shaping the result:
    /// a line's end follows the pencil; other shapes grow or shrink about their center.
    func adjusted(holdPoint: CGPoint, pencil: CGPoint) -> RecognizedShape {
        switch self {
        case .line(let start, _):
            return .line(from: start, to: pencil)
        default:
            let center = self.center
            let original = hypot(holdPoint.x - center.x, holdPoint.y - center.y)
            guard original > 1 else { return self }
            let factor = min(max(hypot(pencil.x - center.x, pencil.y - center.y) / original, 0.2), 5)
            return scaled(by: factor, about: center)
        }
    }

    private func scaled(by factor: CGFloat, about center: CGPoint) -> RecognizedShape {
        func scale(_ point: CGPoint) -> CGPoint {
            CGPoint(x: center.x + (point.x - center.x) * factor, y: center.y + (point.y - center.y) * factor)
        }
        switch self {
        case .line(let start, let end):
            return .line(from: scale(start), to: scale(end))
        case .ellipse(let ellipseCenter, let radii, let rotation):
            return .ellipse(center: scale(ellipseCenter),
                            radii: CGSize(width: radii.width * factor, height: radii.height * factor),
                            rotation: rotation)
        case .polygon(let points):
            return .polygon(points.map(scale))
        case .polyline(let points):
            return .polyline(points.map(scale))
        }
    }

    private static func edges(through corners: [CGPoint], spacing: CGFloat) -> [OutlinePoint] {
        var result: [OutlinePoint] = []
        for (index, corner) in corners.enumerated() {
            result.append(OutlinePoint(point: corner, isCorner: true))
            guard index + 1 < corners.count else { break }
            let next = corners[index + 1]
            let steps = Int(hypot(next.x - corner.x, next.y - corner.y) / max(spacing, 1))
            guard steps > 1 else { continue }
            for step in 1..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(OutlinePoint(point: CGPoint(x: corner.x + (next.x - corner.x) * t,
                                                          y: corner.y + (next.y - corner.y) * t),
                                           isCorner: false))
            }
        }
        return result
    }
}

/// Classifies a rough stroke as a line, ellipse, polygon or polyline, or rejects it.
///
/// Purely geometric and deterministic: every candidate is fitted to the stroke and must stay within
/// a tight error bound, so handwriting that merely resembles a shape is left alone (returns nil).
enum ShapeRecognizer {
    /// Strokes shorter than this (in canvas points) are never shapes.
    static let minimumLength: CGFloat = 40

    static func recognize(_ rawPoints: [CGPoint]) -> RecognizedShape? {
        let length = pathLength(rawPoints)
        guard rawPoints.count >= 4, length >= minimumLength else { return nil }
        let points = resample(rawPoints, count: 72)
        guard let first = points.first, let last = points.last else { return nil }

        let bounds = boundingBox(points)
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 1 else { return nil }
        let gap = hypot(last.x - first.x, last.y - first.y)

        if gap > 0.18 * length {
            return openShape(points, length: length, chord: gap, diagonal: diagonal)
        }
        return closedShape(points, diagonal: diagonal)
    }

    // MARK: Open strokes

    private static func openShape(_ points: [CGPoint], length: CGFloat, chord: CGFloat, diagonal: CGFloat) -> RecognizedShape? {
        let first = points[0]
        let last = points[points.count - 1]

        let deviation = points.map { distance(from: $0, toSegment: first, last) }.max() ?? 0
        if deviation <= 0.07 * chord, length <= 1.2 * chord {
            return .line(from: first, to: snappedEnd(from: first, to: last))
        }

        let corners = simplify(points, tolerance: 0.05 * diagonal)
        guard (3...6).contains(corners.count) else { return nil }
        let shortestEdge = zip(corners, corners.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.min() ?? 0
        guard shortestEdge >= 0.12 * diagonal,
              meanDistance(from: points, toPath: corners) <= 0.022 * diagonal else { return nil }
        return .polyline(corners)
    }

    /// Lines within 3° of horizontal or vertical become exactly so; the start point never moves.
    private static func snappedEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let angle = abs(atan2(end.y - start.y, end.x - start.x))
        let tolerance = 3 * CGFloat.pi / 180
        if angle < tolerance || angle > .pi - tolerance { return CGPoint(x: end.x, y: start.y) }
        if abs(angle - .pi / 2) < tolerance { return CGPoint(x: start.x, y: end.y) }
        return end
    }

    // MARK: Closed strokes

    private static func closedShape(_ points: [CGPoint], diagonal: CGFloat) -> RecognizedShape? {
        let ellipse = fitEllipse(points)
        let polygon = fitPolygon(points, diagonal: diagonal)

        // Normalized so that 1.0 is "just acceptable" for either candidate.
        let ellipseScore = ellipse.map { $0.error / 0.09 } ?? .infinity
        let polygonScore = polygon.map { $0.error / 0.022 } ?? .infinity
        guard min(ellipseScore, polygonScore) <= 1 else { return nil }

        if polygonScore <= ellipseScore, let polygon {
            return .polygon(regularized(polygon.corners))
        }
        return ellipse?.shape
    }

    private static func fitEllipse(_ points: [CGPoint]) -> (shape: RecognizedShape, error: CGFloat)? {
        let count = CGFloat(points.count)
        let mean = CGPoint(x: points.reduce(0) { $0 + $1.x } / count, y: points.reduce(0) { $0 + $1.y } / count)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for point in points {
            let dx = point.x - mean.x, dy = point.y - mean.y
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        // Principal axis of the point cloud; snapped upright when nearly axis-aligned.
        var rotation = 0.5 * atan2(2 * sxy, sxx - syy)
        let snap = 8 * CGFloat.pi / 180
        if abs(rotation) < snap || abs(abs(rotation) - .pi / 2) < snap { rotation = 0 }

        let local = points.map { rotate($0, by: -rotation, about: mean) }
        let box = boundingBox(local)
        var radii = CGSize(width: box.width / 2, height: box.height / 2)
        guard radii.width > 4, radii.height > 4 else { return nil }
        let localCenter = CGPoint(x: box.midX, y: box.midY)

        let squaredError = local.reduce(CGFloat(0)) { sum, point in
            let nx = (point.x - localCenter.x) / radii.width
            let ny = (point.y - localCenter.y) / radii.height
            let radial = sqrt(nx * nx + ny * ny) - 1
            return sum + radial * radial
        }
        let error = sqrt(squaredError / count)

        // The center was measured in the rotated frame; bring it back before any further snapping.
        let center = rotate(localCenter, by: rotation, about: mean)

        // Nearly round: make it a true circle.
        if abs(radii.width - radii.height) / max(radii.width, radii.height) < 0.12 {
            let radius = (radii.width + radii.height) / 2
            radii = CGSize(width: radius, height: radius)
            rotation = 0
        }
        return (.ellipse(center: center, radii: radii, rotation: rotation), error)
    }

    private static func fitPolygon(_ points: [CGPoint], diagonal: CGFloat) -> (corners: [CGPoint], error: CGFloat)? {
        // Start the loop at the point farthest from the centroid, which is always a corner.
        let count = CGFloat(points.count)
        let centroid = CGPoint(x: points.reduce(0) { $0 + $1.x } / count, y: points.reduce(0) { $0 + $1.y } / count)
        guard let startIndex = points.indices.max(by: {
            hypot(points[$0].x - centroid.x, points[$0].y - centroid.y) < hypot(points[$1].x - centroid.x, points[$1].y - centroid.y)
        }) else { return nil }
        let loop = Array(points[startIndex...] + points[..<startIndex]) + [points[startIndex]]

        var corners = simplify(loop, tolerance: 0.06 * diagonal)
        corners.removeLast()
        // Merge corners that landed almost on top of each other (overshoot where the stroke closes).
        var merged: [CGPoint] = []
        for corner in corners {
            if let previous = merged.last, hypot(corner.x - previous.x, corner.y - previous.y) < 0.1 * diagonal { continue }
            merged.append(corner)
        }
        if merged.count > 3, let firstCorner = merged.first, let lastCorner = merged.last,
           hypot(firstCorner.x - lastCorner.x, firstCorner.y - lastCorner.y) < 0.1 * diagonal {
            merged.removeLast()
        }
        guard (3...6).contains(merged.count) else { return nil }
        let error = meanDistance(from: points, toPath: merged + [merged[0]]) / diagonal
        return (merged, error)
    }

    /// Quadrilaterals with four near-right angles become true rectangles (squares when nearly equal).
    private static func regularized(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return corners }
        for index in 0..<4 {
            let previous = corners[(index + 3) % 4], current = corners[index], next = corners[(index + 1) % 4]
            let a = CGPoint(x: previous.x - current.x, y: previous.y - current.y)
            let b = CGPoint(x: next.x - current.x, y: next.y - current.y)
            let cosine = (a.x * b.x + a.y * b.y) / max(hypot(a.x, a.y) * hypot(b.x, b.y), 0.001)
            if abs(cosine) > 0.31 { return corners }   // more than ~18° away from a right angle
        }

        let center = CGPoint(x: corners.reduce(0) { $0 + $1.x } / 4, y: corners.reduce(0) { $0 + $1.y } / 4)
        // Average edge direction, folded into ±45°.
        var orientation = atan2(corners[1].y - corners[0].y, corners[1].x - corners[0].x)
        orientation = orientation - (orientation / (.pi / 2)).rounded() * (.pi / 2)
        if abs(orientation) < 7 * CGFloat.pi / 180 { orientation = 0 }

        let box = boundingBox(corners.map { rotate($0, by: -orientation, about: center) })
        var width = box.width, height = box.height
        if abs(width - height) / max(width, height, 1) < 0.1 {
            width = (width + height) / 2
            height = width
        }
        let boxCenter = CGPoint(x: box.midX, y: box.midY)
        let local = [CGPoint(x: boxCenter.x - width / 2, y: boxCenter.y - height / 2),
                     CGPoint(x: boxCenter.x + width / 2, y: boxCenter.y - height / 2),
                     CGPoint(x: boxCenter.x + width / 2, y: boxCenter.y + height / 2),
                     CGPoint(x: boxCenter.x - width / 2, y: boxCenter.y + height / 2)]
        return local.map { rotate($0, by: orientation, about: center) }
    }

    // MARK: Geometry helpers

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    private static func rotate(_ point: CGPoint, by angle: CGFloat, about center: CGPoint) -> CGPoint {
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(angle) - dy * sin(angle), y: center.y + dx * sin(angle) + dy * cos(angle))
    }

    /// Evenly spaced points along the stroke, so slow and fast parts weigh the same.
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let total = pathLength(points)
        guard total > 0, count > 1 else { return points }
        let step = total / CGFloat(count - 1)
        var result = [points[0]]
        var carried: CGFloat = 0
        var previous = points[0]
        for point in points.dropFirst() {
            var segment = hypot(point.x - previous.x, point.y - previous.y)
            while carried + segment >= step, segment > 0 {
                let t = (step - carried) / segment
                previous = CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t)
                result.append(previous)
                segment = hypot(point.x - previous.x, point.y - previous.y)
                carried = 0
            }
            carried += segment
            previous = point
        }
        if result.count < count, let last = points.last { result.append(last) }
        return result
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    private static func meanDistance(from points: [CGPoint], toPath path: [CGPoint]) -> CGFloat {
        guard path.count > 1, !points.isEmpty else { return .infinity }
        let total = points.reduce(CGFloat(0)) { sum, point in
            sum + (zip(path, path.dropFirst()).map { distance(from: point, toSegment: $0, $1) }.min() ?? 0)
        }
        return total / CGFloat(points.count)
    }

    /// Ramer–Douglas–Peucker: keeps only the points needed to stay within `tolerance` of the stroke.
    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var farthest = 0
        var farthestDistance: CGFloat = 0
        for index in 1..<(points.count - 1) {
            let d = distance(from: points[index], toSegment: first, last)
            if d > farthestDistance {
                farthestDistance = d
                farthest = index
            }
        }
        guard farthestDistance > tolerance else { return [first, last] }
        let head = simplify(Array(points[...farthest]), tolerance: tolerance)
        let tail = simplify(Array(points[farthest...]), tolerance: tolerance)
        return Array(head.dropLast()) + tail
    }
}
