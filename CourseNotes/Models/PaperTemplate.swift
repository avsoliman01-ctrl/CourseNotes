import UIKit

/// Fixed geometry of a note, in canvas content coordinates (the coordinate space of `PKDrawing`).
enum CanvasMetrics {
    /// Width of the writable page. The canvas zooms so this width exactly fills the screen,
    /// which keeps handwriting in place across portrait, landscape and Split View.
    static let pageWidth: CGFloat = 1024
    /// Height of one exported PDF page (US Letter aspect ratio).
    static let pageHeight: CGFloat = pageWidth * 11 / 8.5
    /// Blank space kept below the lowest stroke so there is always room to keep writing.
    static let overscrollHeight: CGFloat = 600
    /// How far the user can pinch-zoom in, relative to "page fits width".
    static let maximumZoomMultiplier: CGFloat = 4
    /// Aspect ratio (width / height) of dashboard thumbnails.
    static let thumbnailAspectRatio: CGFloat = 4.0 / 3.0
}

enum PaperTemplate: String, Codable, CaseIterable, Identifiable {
    case blank
    case grid
    case collegeRuled
    case dotGrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blank: "Blank"
        case .grid: "Graph Paper"
        case .collegeRuled: "College Ruled"
        case .dotGrid: "Dot Grid"
        }
    }

    var symbolName: String {
        switch self {
        case .blank: "square"
        case .grid: "squareshape.split.3x3"
        case .collegeRuled: "line.3.horizontal"
        case .dotGrid: "circle.grid.3x3"
        }
    }
}

/// Colors and spacing of the printed-paper look. Spacing is in canvas content points.
enum PaperStyle {
    static let paper = UIColor.white
    static let ruleLine = UIColor(red: 0.55, green: 0.70, blue: 0.88, alpha: 0.80)
    static let marginLine = UIColor(red: 0.90, green: 0.38, blue: 0.40, alpha: 0.75)
    static let gridMinor = UIColor(red: 0.55, green: 0.70, blue: 0.88, alpha: 0.40)
    static let gridMajor = UIColor(red: 0.42, green: 0.60, blue: 0.84, alpha: 0.65)
    static let dot = UIColor(white: 0.55, alpha: 0.85)

    static let ruleSpacing: CGFloat = 40
    static let ruleTopMargin: CGFloat = 120
    static let marginX: CGFloat = 96
    static let gridSpacing: CGFloat = 32
    static let gridMajorEvery = 5
    static let dotSpacing: CGFloat = 32
    static let dotRadius: CGFloat = 1.6
}

extension PaperTemplate {
    /// Draws the template for the part of the page described by `contentRect`.
    ///
    /// The caller prepares the context's CTM so that drawing in canvas content coordinates lands
    /// in the right place. `zoomScale` (device points per content point) keeps hairlines crisp
    /// when zoomed out. The same routine renders the live canvas, thumbnails and PDF pages,
    /// so all three always match.
    func draw(in context: CGContext, contentRect: CGRect, zoomScale: CGFloat) {
        let page = CGRect(x: 0, y: 0, width: CanvasMetrics.pageWidth, height: 10_000_000)
        let rect = contentRect.intersection(page)
        guard self != .blank, !rect.isNull, rect.width > 0, rect.height > 0 else { return }

        let lineWidth = max(0.75, 0.5 / max(zoomScale, 0.01))
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(lineWidth)

        switch self {
        case .blank:
            break
        case .collegeRuled:
            drawRuledLines(in: context, rect: rect)
        case .grid:
            drawGrid(in: context, rect: rect, lineWidth: lineWidth)
        case .dotGrid:
            drawDots(in: context, rect: rect, zoomScale: zoomScale)
        }
    }

    private func drawRuledLines(in context: CGContext, rect: CGRect) {
        let spacing = PaperStyle.ruleSpacing
        let top = PaperStyle.ruleTopMargin
        let first = max(0, Int(ceil((rect.minY - top) / spacing)))
        let last = Int(floor((rect.maxY - top) / spacing))

        if first <= last {
            let path = CGMutablePath()
            for index in first...last {
                let y = top + CGFloat(index) * spacing
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.addPath(path)
            context.setStrokeColor(PaperStyle.ruleLine.cgColor)
            context.strokePath()
        }

        if (rect.minX...rect.maxX).contains(PaperStyle.marginX) {
            context.move(to: CGPoint(x: PaperStyle.marginX, y: rect.minY))
            context.addLine(to: CGPoint(x: PaperStyle.marginX, y: rect.maxY))
            context.setStrokeColor(PaperStyle.marginLine.cgColor)
            context.strokePath()
        }
    }

    private func drawGrid(in context: CGContext, rect: CGRect, lineWidth: CGFloat) {
        let spacing = PaperStyle.gridSpacing
        let minor = CGMutablePath()
        let major = CGMutablePath()

        let firstColumn = Int(ceil(rect.minX / spacing))
        let lastColumn = Int(floor(rect.maxX / spacing))
        if firstColumn <= lastColumn {
            for index in firstColumn...lastColumn {
                let x = CGFloat(index) * spacing
                let path = index % PaperStyle.gridMajorEvery == 0 ? major : minor
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
        }

        let firstRow = Int(ceil(rect.minY / spacing))
        let lastRow = Int(floor(rect.maxY / spacing))
        if firstRow <= lastRow {
            for index in firstRow...lastRow {
                let y = CGFloat(index) * spacing
                let path = index % PaperStyle.gridMajorEvery == 0 ? major : minor
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }

        context.addPath(minor)
        context.setStrokeColor(PaperStyle.gridMinor.cgColor)
        context.strokePath()

        context.setLineWidth(lineWidth * 1.4)
        context.addPath(major)
        context.setStrokeColor(PaperStyle.gridMajor.cgColor)
        context.strokePath()
    }

    private func drawDots(in context: CGContext, rect: CGRect, zoomScale: CGFloat) {
        let spacing = PaperStyle.dotSpacing
        // Keep dots visible (at least ~1 device point across) when zoomed out.
        let radius = max(PaperStyle.dotRadius, 0.6 / max(zoomScale, 0.01))
        let firstColumn = Int(ceil(rect.minX / spacing))
        let lastColumn = Int(floor(rect.maxX / spacing))
        let firstRow = Int(ceil(rect.minY / spacing))
        let lastRow = Int(floor(rect.maxY / spacing))
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return }

        let path = CGMutablePath()
        for row in firstRow...lastRow {
            let y = CGFloat(row) * spacing
            for column in firstColumn...lastColumn {
                let x = CGFloat(column) * spacing
                path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
        context.addPath(path)
        context.setFillColor(PaperStyle.dot.cgColor)
        context.fillPath()
    }
}
