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

    var template: PaperTemplate = .blank {
        didSet {
            if template != oldValue { paperView.template = template }
        }
    }

    private var lastLayoutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Paper stays white in Dark Mode; this also stops PencilKit from inverting ink colors.
        overrideUserInterfaceStyle = .light
        backgroundColor = PaperStyle.paper

        paperView.isUserInteractionEnabled = false
        reticleView.isUserInteractionEnabled = false

        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.alwaysBounceVertical = true
        canvasView.showsHorizontalScrollIndicator = false

        addSubview(paperView)
        addSubview(canvasView)
        addSubview(reticleView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperView.frame = bounds
        canvasView.frame = bounds
        reticleView.frame = bounds
        updateZoomForCurrentWidth()
        updateContentSize()
        syncPaperWithCanvas()
    }

    /// Page width × (lowest stroke + overscroll); never shorter than one page or the screen.
    func updateContentSize() {
        let zoom = canvasView.zoomScale
        let inkBounds = canvasView.drawing.bounds
        let inkBottom = inkBounds.isNull ? 0 : inkBounds.maxY
        let pageHeight = max(CanvasMetrics.pageHeight, inkBottom + CanvasMetrics.overscrollHeight) * zoom
        canvasView.contentSize = CGSize(width: CanvasMetrics.pageWidth * zoom, height: max(pageHeight, bounds.height))
    }

    func syncPaperWithCanvas() {
        paperView.update(contentOffset: canvasView.contentOffset, zoomScale: canvasView.zoomScale)
        reticleView.zoomScale = canvasView.zoomScale
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

    private var contentOffset: CGPoint = .zero
    private var zoomScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = PaperStyle.paper
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
        if template != .blank { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        PaperStyle.paper.setFill()
        context.fill(rect)
        guard template != .blank, zoomScale > 0 else { return }

        // View point = content point × zoom − offset.
        context.translateBy(x: -contentOffset.x, y: -contentOffset.y)
        context.scaleBy(x: zoomScale, y: zoomScale)
        let visibleContent = CGRect(x: (contentOffset.x + rect.minX) / zoomScale,
                                    y: (contentOffset.y + rect.minY) / zoomScale,
                                    width: rect.width / zoomScale,
                                    height: rect.height / zoomScale)
        template.draw(in: context, contentRect: visibleContent, zoomScale: zoomScale)
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

    func configure(for tool: ToolConfiguration) {
        switch tool.kind {
        case .eraser:
            style = .eraser
            toolWidth = tool.eraserMode == .pixel ? tool.width : 10
        case .lasso:
            style = .lasso
            toolWidth = 8
        default:
            style = .ink(tool.color.uiColor)
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
