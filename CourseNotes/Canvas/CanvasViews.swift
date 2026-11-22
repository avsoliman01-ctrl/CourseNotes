import PencilKit
import UIKit

/// `PKCanvasView` with a private undo stack, so undo never reaches into a different note
/// (the window's shared undo manager would otherwise outlive the canvas).
final class NoteCanvasView: PKCanvasView {
    private let noteUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 200
        return manager
    }()

    override var undoManager: UndoManager? { noteUndoManager }
}

/// Paper background, transparent `PKCanvasView` and hover reticle, stacked.
///
/// The ink lives in a fixed-width page (`CanvasMetrics.pageWidth`) that is zoomed to fill the view,
/// so handwriting stays put across rotation, Split View and Stage Manager resizing. The paper view
/// redraws from the canvas's offset and zoom, so templates scroll and pinch-zoom with the ink.
final class CanvasContainerView: UIView {
    let paperView = PaperBackgroundView()
    let canvasView = NoteCanvasView()
    let reticleView = HoverReticleView()
    /// Custom lasso (select, move, resize, recolor). Its overlay sits between the ink and the reticle.
    private(set) var selection: LassoSelectionController!
    /// Hold-to-correct shapes and handwriting smoothing.
    private(set) var assistant: InkAssistant!

    var template: PaperTemplate = .blank {
        didSet {
            if template != oldValue { paperView.template = template }
        }
    }

    /// White or black paper. The canvas's appearance follows, so PencilKit shows the stored
    /// light-mode ink adapted for the paper (black ink draws and displays as white on black).
    var paperAppearance: PaperAppearance = .light {
        didSet {
            guard paperAppearance != oldValue else { return }
            applyPaperAppearance()
        }
    }

    private var lastLayoutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        applyPaperAppearance()

        paperView.isUserInteractionEnabled = false
        reticleView.isUserInteractionEnabled = false

        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.alwaysBounceVertical = true
        canvasView.showsHorizontalScrollIndicator = false

        addSubview(paperView)
        addSubview(canvasView)
        selection = LassoSelectionController(canvasView: canvasView, hostView: self)
        addSubview(selection.overlay)
        assistant = InkAssistant(canvasView: canvasView, overlayLayer: selection.overlay.layer)
        addSubview(reticleView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The paper's appearance is fixed by the setting, never by whatever the app's UI happens to be.
    private func applyPaperAppearance() {
        overrideUserInterfaceStyle = paperAppearance.interfaceStyle
        backgroundColor = paperAppearance.colors.paper
        paperView.colors = paperAppearance.colors
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperView.frame = bounds
        canvasView.frame = bounds
        selection.overlay.frame = bounds
        reticleView.frame = bounds
        updateZoomForCurrentWidth()
        updateContentSize()
        syncPaperWithCanvas()
    }

    /// Pages currently available to scroll through. Grows as ink or scrolling nears the end and
    /// never shrinks while the note is open, so the page under the pencil can't disappear.
    private var allocatedPages = CanvasMetrics.minimumPages

    /// Whole pages: at least `minimumPages`, and always a blank page below the last inked one.
    /// Scroll extent no longer depends on where the lowest stroke happens to be.
    func updateContentSize() {
        let zoom = canvasView.zoomScale
        let inkBounds = canvasView.drawing.bounds
        let inkBottom = inkBounds.isNull ? 0 : inkBounds.maxY
        let inkedPages = Int((inkBottom / CanvasMetrics.pageHeight).rounded(.up))
        allocatedPages = min(CanvasMetrics.maximumPages,
                             max(allocatedPages, CanvasMetrics.minimumPages, inkedPages + CanvasMetrics.blankPagesBelowInk))

        let height = CGFloat(allocatedPages) * CanvasMetrics.pageHeight * zoom
        let size = CGSize(width: CanvasMetrics.pageWidth * zoom, height: max(height, bounds.height))
        if canvasView.contentSize != size {
            canvasView.contentSize = size
        }
    }

    /// Adds a page when the visible area gets within half a page of the end, so there is always
    /// more paper to scroll onto before writing anything.
    func extendPagesIfNeededForScrolling() {
        guard allocatedPages < CanvasMetrics.maximumPages else { return }
        let zoom = max(canvasView.zoomScale, 0.01)
        let visibleBottom = (canvasView.contentOffset.y + canvasView.bounds.height) / zoom
        let allocatedBottom = CGFloat(allocatedPages) * CanvasMetrics.pageHeight
        if visibleBottom > allocatedBottom - CanvasMetrics.pageHeight / 2 {
            allocatedPages += 1
            updateContentSize()
        }
    }

    func syncPaperWithCanvas() {
        paperView.update(contentOffset: canvasView.contentOffset, zoomScale: canvasView.zoomScale)
        reticleView.zoomScale = canvasView.zoomScale
        selection.refreshOverlay()
    }

    func zoomToFitWidth(animated: Bool) {
        canvasView.setZoomScale(canvasView.minimumZoomScale, animated: animated)
    }

    /// Keeps "page fits width" as the minimum zoom. When the width changes, preserves the user's
    /// relative zoom and the content row at the top of the screen.
    private func updateZoomForCurrentWidth() {
        let width = bounds.width
        guard width > 0, width != lastLayoutWidth else { return }

        let fitScale = width / CanvasMetrics.pageWidth
        let oldZoom = max(canvasView.zoomScale, 0.01)
        let relativeZoom = lastLayoutWidth > 0 ? max(1, oldZoom / (lastLayoutWidth / CanvasMetrics.pageWidth)) : 1
        let topContentY = canvasView.contentOffset.y / oldZoom
        let leftContentX = canvasView.contentOffset.x / oldZoom
        lastLayoutWidth = width

        // Raise the maximum first so the minimum is never above it.
        canvasView.maximumZoomScale = fitScale * CanvasMetrics.maximumZoomMultiplier
        canvasView.minimumZoomScale = fitScale
        canvasView.zoomScale = fitScale * relativeZoom
        updateContentSize()

        let zoom = canvasView.zoomScale
        let maxX = max(0, canvasView.contentSize.width - width)
        let maxY = max(0, canvasView.contentSize.height - bounds.height)
        canvasView.contentOffset = CGPoint(x: min(max(0, leftContentX * zoom), maxX),
                                           y: min(max(0, topContentY * zoom), maxY))
    }
}

/// Draws the paper template for whatever part of the page is visible.
final class PaperBackgroundView: UIView {
    var template: PaperTemplate = .blank {
        didSet { setNeedsDisplay() }
    }

    var colors: PaperColors = .light {
        didSet {
            backgroundColor = colors.paper
            setNeedsDisplay()
        }
    }

    private var contentOffset: CGPoint = .zero
    private var zoomScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = colors.paper
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(contentOffset: CGPoint, zoomScale: CGFloat) {
        guard contentOffset != self.contentOffset || zoomScale != self.zoomScale else { return }
        self.contentOffset = contentOffset
        self.zoomScale = zoomScale
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        colors.paper.setFill()
        context.fill(rect)
        guard zoomScale > 0 else { return }

        // View point = content point × zoom − offset.
        context.translateBy(x: -contentOffset.x, y: -contentOffset.y)
        context.scaleBy(x: zoomScale, y: zoomScale)
        let visibleContent = CGRect(x: (contentOffset.x + rect.minX) / zoomScale,
                                    y: (contentOffset.y + rect.minY) / zoomScale,
                                    width: rect.width / zoomScale,
                                    height: rect.height / zoomScale)
        template.draw(in: context, contentRect: visibleContent, zoomScale: zoomScale, colors: colors)
        drawPageBreaks(in: context, visibleContent: visibleContent)
    }

    /// Faint dashed rule where one exported PDF page ends and the next begins. Drawn in the same
    /// content coordinates as the ink and the template, so all three stay aligned at any zoom.
    private func drawPageBreaks(in context: CGContext, visibleContent: CGRect) {
        let pageHeight = CanvasMetrics.pageHeight
        let first = max(1, Int((visibleContent.minY / pageHeight).rounded(.up)))
        let last = Int((visibleContent.maxY / pageHeight).rounded(.down))
        guard first <= last else { return }

        let unit = 1 / zoomScale
        context.saveGState()
        context.setStrokeColor(colors.pageBreak.cgColor)
        context.setLineWidth(unit)
        context.setLineDash(phase: 0, lengths: [8 * unit, 6 * unit])
        for page in first...last {
            let y = CGFloat(page) * pageHeight
            context.move(to: CGPoint(x: max(0, visibleContent.minX), y: y))
            context.addLine(to: CGPoint(x: min(CanvasMetrics.pageWidth, visibleContent.maxX), y: y))
        }
        context.strokePath()
        context.restoreGState()
    }
}

/// Hover indicator for Apple Pencil (hover works on M2-and-later iPads, including iPad Air M2).
///
/// Complements PencilKit's built-in ink preview: the ellipse is the tip's footprint for the
/// current tilt (stretched along the azimuth as the pencil leans), the tick follows Apple Pencil Pro
/// barrel roll, and the ring fades with hover height. For the pixel eraser it shows the exact
/// erase width, which PencilKit does not preview.
final class HoverReticleView: UIView {
    struct Pose {
        var location: CGPoint
        /// 0 (touching) ... 1 (farthest detectable hover).
        var zOffset: CGFloat
        /// 0 = pencil flat against the glass, π/2 = perpendicular.
        var altitude: CGFloat
        /// Direction the pencil points, in this view's coordinate space.
        var azimuth: CGFloat
        /// Barrel roll (Apple Pencil Pro only; 0 on other pencils).
        var roll: CGFloat
    }

    private enum Style {
        case ink(UIColor)
        case eraser
        case lasso
    }

    var zoomScale: CGFloat = 1

    private var toolWidth: CGFloat = 3
    private var style: Style = .ink(.black)
    private let footprintLayer = CAShapeLayer()
    private let rollLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isHidden = true
        for shape in [footprintLayer, rollLayer] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 1.5
            shape.lineCap = .round
            shape.shadowColor = UIColor.black.cgColor
            shape.shadowOpacity = 0.25
            shape.shadowRadius = 1
            shape.shadowOffset = .zero
            layer.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `appearance` is the paper's: on dark paper the reticle shows the ink as PencilKit will draw it.
    func configure(for tool: ToolConfiguration, appearance: PaperAppearance) {
        switch tool.kind {
        case .eraser:
            style = .eraser
            toolWidth = tool.eraserMode == .pixel ? tool.width : 10
        case .lasso:
            style = .lasso
            toolWidth = 8
        default:
            style = .ink(tool.color.displayedUIColor(on: appearance))
            toolWidth = tool.width
        }

        let stroke: UIColor
        switch style {
        case .ink(let color): stroke = color.withAlphaComponent(0.9)
        case .eraser: stroke = .systemGray
        case .lasso: stroke = .systemBlue
        }
        footprintLayer.strokeColor = stroke.cgColor
        rollLayer.strokeColor = stroke.cgColor
        switch style {
        case .ink: footprintLayer.lineDashPattern = nil
        case .eraser, .lasso: footprintLayer.lineDashPattern = [4, 3]
        }
    }

    func show(_ pose: Pose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let diameter = max(10, toolWidth * zoomScale)
        // Leaning the pencil stretches its footprint: 1× upright, up to 2.5× when nearly flat.
        let tilt = 1 - min(max(pose.altitude / (.pi / 2), 0), 1)
        let stretch = 1 + tilt * 1.5
        let footprint = CGRect(x: -diameter * stretch / 2, y: -diameter / 2, width: diameter * stretch, height: diameter)
        var footprintTransform = CGAffineTransform(translationX: pose.location.x, y: pose.location.y)
            .rotated(by: pose.azimuth)
        footprintLayer.path = CGPath(ellipseIn: footprint, transform: &footprintTransform)

        let rollTransform = CGAffineTransform(translationX: pose.location.x, y: pose.location.y)
            .rotated(by: pose.roll)
        let inner = diameter / 2 + 3
        let tick = CGMutablePath()
        tick.move(to: CGPoint(x: 0, y: -inner), transform: rollTransform)
        tick.addLine(to: CGPoint(x: 0, y: -(inner + 8)), transform: rollTransform)
        rollLayer.path = tick

        layer.opacity = Float(1 - min(max(pose.zOffset, 0), 1) * 0.6)
        isHidden = false
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
    }
}
