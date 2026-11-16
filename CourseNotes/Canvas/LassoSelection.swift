import PencilKit
import UIKit

/// Custom lasso for `PKCanvasView`: select strokes, then move, resize, recolor, duplicate or delete them.
///
/// PencilKit's own `PKLassoTool` keeps its selection private, so this works on the public stroke
/// model instead. Moving and resizing concatenate onto `PKStroke.transform` and recoloring replaces
/// `PKStroke.ink`. The stroke paths themselves are never resampled, so repeated edits don't degrade
/// the handwriting, and the result is ordinary `PKDrawing` data that saves and reloads like any ink.
@MainActor
final class LassoSelectionController: NSObject, UIGestureRecognizerDelegate {
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// Position on the unit square (0...1).
        var unit: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0)
            case .top: CGPoint(x: 0.5, y: 0)
            case .topRight: CGPoint(x: 1, y: 0)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottomRight: CGPoint(x: 1, y: 1)
            case .bottom: CGPoint(x: 0.5, y: 1)
            case .bottomLeft: CGPoint(x: 0, y: 1)
            case .left: CGPoint(x: 0, y: 0.5)
            }
        }

        var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }

        func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
        }

        /// The point that stays fixed while this handle is dragged.
        func anchor(in rect: CGRect) -> CGPoint {
            CGPoint(x: rect.minX + (1 - unit.x) * rect.width, y: rect.minY + (1 - unit.y) * rect.height)
        }
    }

    private enum Interaction {
        case idle
        case lassoing([CGPoint])
        case moving
        case resizing(Handle)
    }

    let overlay = SelectionOverlayView()

    /// Called with the number of selected strokes whenever the selection changes.
    var onSelectionChange: ((Int) -> Void)?
    /// Called after an edit has been committed to the canvas (for autosave and undo state).
    var onCommit: (() -> Void)?
    /// When true, a single finger may lasso too (two fingers still scroll).
    var allowsFingerInput = false

    /// True while selected strokes are temporarily lifted off the canvas during a drag.
    /// The canvas delegate must ignore drawing changes while this is set, so a half-finished
    /// move is never autosaved.
    private(set) var isLiftingStrokes = false
    /// True while this controller is the one writing to `canvasView.drawing`.
    private(set) var isApplyingEdit = false

    private weak var canvasView: PKCanvasView?
    private weak var hostView: UIView?
    private let panRecognizer = UIPanGestureRecognizer()
    private let tapRecognizer = UITapGestureRecognizer()

    private var selectedIndices: [Int] = []
    private var interaction: Interaction = .idle
    /// Drawing as it was before the current drag lifted the selection.
    private var baseDrawing: PKDrawing?
    private var baseBounds: CGRect = .null
    private var pendingTransform: CGAffineTransform = .identity
    private var lastRecolorDate: Date = .distantPast

    var hasSelection: Bool { !selectedIndices.isEmpty }

    init(canvasView: PKCanvasView, hostView: UIView) {
        self.canvasView = canvasView
        self.hostView = hostView
        super.init()

        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        panRecognizer.maximumNumberOfTouches = 1
        panRecognizer.delegate = self
        tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        tapRecognizer.delegate = self
        hostView.addGestureRecognizer(panRecognizer)
        hostView.addGestureRecognizer(tapRecognizer)
        setEnabled(false)
    }

    /// Lasso mode: PencilKit's drawing gesture is switched off and this controller takes the pencil.
    func setEnabled(_ enabled: Bool) {
        guard panRecognizer.isEnabled != enabled || tapRecognizer.isEnabled != enabled else { return }
        panRecognizer.isEnabled = enabled
        tapRecognizer.isEnabled = enabled
        canvasView?.drawingGestureRecognizer.isEnabled = !enabled
        if !enabled { clearSelection() }
    }

    // MARK: Selection

    func clearSelection() {
        cancelLift()
        interaction = .idle
        guard hasSelection || overlay.hasContent else { return }
        selectedIndices = []
        refreshOverlay()
        onSelectionChange?(0)
    }

    /// The canvas changed for a reason other than this controller (undo, redo, erase).
    func drawingChangedExternally() {
        guard !isApplyingEdit, !isLiftingStrokes else { return }
        clearSelection()
    }

    /// Bounds of the selection in canvas content coordinates.
    var selectionBounds: CGRect {
        guard let drawing = canvasView?.drawing else { return .null }
        return bounds(of: selectedIndices, in: drawing)
    }

    private func bounds(of indices: [Int], in drawing: PKDrawing) -> CGRect {
        indices.reduce(CGRect.null) { partial, index in
            index < drawing.strokes.count ? partial.union(drawing.strokes[index].renderBounds) : partial
        }
    }

    private func select(_ indices: [Int]) {
        selectedIndices = indices
        refreshOverlay()
        onSelectionChange?(indices.count)
    }

    /// Strokes with most of their control points inside the lasso.
    private func strokeIndices(inside polygon: [CGPoint]) -> [Int] {
        guard polygon.count >= 3, let drawing = canvasView?.drawing else { return [] }
        let path = UIBezierPath()
        path.move(to: polygon[0])
        polygon.dropFirst().forEach { path.addLine(to: $0) }
        path.close()
        let lassoBounds = path.bounds

        return drawing.strokes.indices.filter { index in
            let stroke = drawing.strokes[index]
            guard stroke.renderBounds.intersects(lassoBounds) else { return false }
            var inside = 0
            var total = 0
            for point in stroke.path {
                total += 1
                if path.contains(point.location.applying(stroke.transform)) { inside += 1 }
            }
            return total > 0 && Double(inside) / Double(total) >= 0.6
        }
    }

    /// Topmost stroke passing within reach of a tap.
    private func strokeIndex(near location: CGPoint, reach: CGFloat) -> Int? {
        guard let drawing = canvasView?.drawing else { return nil }
        return drawing.strokes.indices.reversed().first { index in
            let stroke = drawing.strokes[index]
            guard stroke.renderBounds.insetBy(dx: -reach, dy: -reach).contains(location) else { return false }
            return stroke.path.contains { point in
                let position = point.location.applying(stroke.transform)
                return hypot(position.x - location.x, position.y - location.y) <= reach + point.size.width / 2
            }
        }
    }

    // MARK: Edits (each is one undo step)

    func recolorSelection(_ color: UIColor) {
        guard hasSelection, let drawing = canvasView?.drawing else { return }
        var strokes = drawing.strokes
        for index in selectedIndices where index < strokes.count {
            strokes[index].ink = PKInk(strokes[index].ink.inkType, color: color)
        }
        // Dragging through the system color picker sends a stream of colors; fold them into one undo step.
        let continuesPreviousRecolor = Date().timeIntervalSince(lastRecolorDate) < 0.75
        lastRecolorDate = Date()
        commit(PKDrawing(strokes: strokes), from: drawing, actionName: "Change Ink Color",
               registersUndo: !continuesPreviousRecolor)
    }

    func deleteSelection() {
        guard hasSelection, let drawing = canvasView?.drawing else { return }
        let doomed = Set(selectedIndices)
        let remaining = drawing.strokes.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
        selectedIndices = []
        commit(PKDrawing(strokes: remaining), from: drawing, actionName: "Delete Selection")
        refreshOverlay()
        onSelectionChange?(0)
    }

    func duplicateSelection() {
        guard hasSelection, let drawing = canvasView?.drawing else { return }
        let offset = CGAffineTransform(translationX: 28, y: 28)
        var strokes = drawing.strokes
        var copies: [Int] = []
        for index in selectedIndices where index < drawing.strokes.count {
            var copy = drawing.strokes[index]
            copy.transform = copy.transform.concatenating(offset)
            copies.append(strokes.count)
            strokes.append(copy)
        }
        commit(PKDrawing(strokes: strokes), from: drawing, actionName: "Duplicate Selection")
        select(copies)
    }

    /// The selected ink on white, for handwriting recognition.
    func selectionImage(scale: CGFloat = 3) -> UIImage? {
        guard hasSelection, let drawing = canvasView?.drawing else { return nil }
        let strokes = selectedIndices.filter { $0 < drawing.strokes.count }.map { drawing.strokes[$0] }
        let rect = bounds(of: selectedIndices, in: drawing).insetBy(dx: -24, dy: -24)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = PKDrawing(strokes: strokes).image(from: rect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
    }

    /// Writes `newDrawing` to the canvas and registers an undo step that restores `oldDrawing`.
    private func commit(_ newDrawing: PKDrawing, from oldDrawing: PKDrawing, actionName: String,
                        registersUndo: Bool = true) {
        guard let canvasView else { return }
        if registersUndo, let undoManager = canvasView.undoManager {
            undoManager.registerUndo(withTarget: self) { controller in
                MainActor.assumeIsolated {
                    // Runs for undo; the nested commit registers the matching redo.
                    guard let current = controller.canvasView?.drawing else { return }
                    controller.clearSelection()
                    controller.commit(oldDrawing, from: current, actionName: actionName)
                }
            }
            undoManager.setActionName(actionName)
        }
        isApplyingEdit = true
        canvasView.drawing = newDrawing
        isApplyingEdit = false
        onCommit?()
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.type == .pencil || (allowsFingerInput && touch.type == .direct)
    }

    /// The canvas must not scroll with the same touch that is drawing a lasso or dragging a handle.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === panRecognizer && otherGestureRecognizer === canvasView?.panGestureRecognizer
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let hostView else { return }
        let location = contentPoint(recognizer.location(in: hostView))
        if hasSelection, selectionBounds.insetBy(dx: -reach, dy: -reach).contains(location) { return }
        if let index = strokeIndex(near: location, reach: reach * 0.6) {
            select([index])
        } else {
            clearSelection()
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let hostView else { return }
        let location = contentPoint(recognizer.location(in: hostView))

        switch recognizer.state {
        case .began:
            let translation = recognizer.translation(in: hostView)
            let start = CGPoint(x: location.x - translation.x / zoom, y: location.y - translation.y / zoom)
            beginInteraction(at: start)
            continueInteraction(to: location, start: start)
        case .changed:
            let translation = recognizer.translation(in: hostView)
            let start = CGPoint(x: location.x - translation.x / zoom, y: location.y - translation.y / zoom)
            continueInteraction(to: location, start: start)
        case .ended:
            endInteraction()
        case .cancelled, .failed:
            cancelLift()
            interaction = .idle
            refreshOverlay()
        default:
            break
        }
    }

    private func beginInteraction(at start: CGPoint) {
        if hasSelection {
            let bounds = selectionBounds
            if let handle = Handle.allCases.first(where: { handle in
                let point = handle.point(in: bounds)
                return hypot(point.x - start.x, point.y - start.y) <= reach
            }) {
                liftSelection()
                interaction = .resizing(handle)
                return
            }
            if bounds.insetBy(dx: -reach / 2, dy: -reach / 2).contains(start) {
                liftSelection()
                interaction = .moving
                return
            }
            clearSelection()
        }
        interaction = .lassoing([start])
    }

    private func continueInteraction(to location: CGPoint, start: CGPoint) {
        switch interaction {
        case .idle:
            break
        case .lassoing(var points):
            points.append(location)
            interaction = .lassoing(points)
            overlay.lassoPoints = points.map(screenPoint)
        case .moving:
            pendingTransform = CGAffineTransform(translationX: location.x - start.x, y: location.y - start.y)
            overlay.floatingFrame = screenRect(liftedImageBounds.applying(pendingTransform))
            overlay.selectionFrame = screenRect(baseBounds.applying(pendingTransform))
        case .resizing(let handle):
            pendingTransform = resizeTransform(for: handle, from: handle.point(in: baseBounds), to: location)
            overlay.floatingFrame = screenRect(liftedImageBounds.applying(pendingTransform))
            overlay.selectionFrame = screenRect(baseBounds.applying(pendingTransform))
        }
    }

    private func endInteraction() {
        switch interaction {
        case .idle:
            break
        case .lassoing(let points):
            interaction = .idle
            overlay.lassoPoints = []
            select(strokeIndices(inside: points))
        case .moving, .resizing:
            interaction = .idle
            dropSelection()
        }
    }

    /// Corner handles scale proportionally; edge handles stretch one axis.
    private func resizeTransform(for handle: Handle, from start: CGPoint, to location: CGPoint) -> CGAffineTransform {
        let anchor = handle.anchor(in: baseBounds)
        let original = CGPoint(x: start.x - anchor.x, y: start.y - anchor.y)
        let current = CGPoint(x: location.x - anchor.x, y: location.y - anchor.y)
        // Never collapse or flip the selection.
        let minimumScale = max(0.05, 12 / max(baseBounds.width, baseBounds.height, 1))
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1

        if handle.isCorner {
            let lengthSquared = original.x * original.x + original.y * original.y
            let projected = lengthSquared > 0 ? (current.x * original.x + current.y * original.y) / lengthSquared : 1
            scaleX = max(minimumScale, projected)
            scaleY = scaleX
        } else if handle.unit.y == 0.5 {
            scaleX = max(minimumScale, abs(original.x) > 0 ? current.x / original.x : 1)
        } else {
            scaleY = max(minimumScale, abs(original.y) > 0 ? current.y / original.y : 1)
        }
        return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }

    // MARK: Lift and drop

    private var liftedImageBounds: CGRect { baseBounds.insetBy(dx: -8, dy: -8) }

    /// Takes the selected strokes off the canvas and shows them as an image that follows the drag.
    /// Transforming a snapshot keeps dragging smooth even in a note with thousands of strokes.
    private func liftSelection() {
        guard let canvasView, !isLiftingStrokes else { return }
        let drawing = canvasView.drawing
        let selected = Set(selectedIndices)
        var lifted: [PKStroke] = []
        var rest: [PKStroke] = []
        for (index, stroke) in drawing.strokes.enumerated() {
            if selected.contains(index) { lifted.append(stroke) } else { rest.append(stroke) }
        }
        guard !lifted.isEmpty else { return }

        baseDrawing = drawing
        baseBounds = bounds(of: selectedIndices, in: drawing)
        pendingTransform = .identity

        let scale = min(max(zoom * (hostView?.traitCollection.displayScale ?? 2), 1), 4)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: lifted).image(from: liftedImageBounds, scale: scale)
        }
        overlay.floatingImage = image
        overlay.floatingFrame = screenRect(liftedImageBounds)

        isLiftingStrokes = true
        canvasView.drawing = PKDrawing(strokes: rest)
    }

    /// Puts the lifted strokes back with the drag's transform applied to their geometry.
    private func dropSelection() {
        guard let canvasView, isLiftingStrokes, let baseDrawing else { return }
        var strokes = baseDrawing.strokes
        let transform = pendingTransform
        if !transform.isIdentity {
            for index in selectedIndices where index < strokes.count {
                strokes[index].transform = strokes[index].transform.concatenating(transform)
            }
        }
        // Restore the untouched drawing first so the undo step captures the true "before" state.
        canvasView.drawing = baseDrawing
        isLiftingStrokes = false
        overlay.floatingImage = nil
        self.baseDrawing = nil
        if !transform.isIdentity {
            let name = transform.a == 1 && transform.d == 1 ? "Move Selection" : "Resize Selection"
            commit(PKDrawing(strokes: strokes), from: baseDrawing, actionName: name)
        }
        pendingTransform = .identity
        refreshOverlay()
    }

    private func cancelLift() {
        guard isLiftingStrokes, let baseDrawing else { return }
        canvasView?.drawing = baseDrawing
        isLiftingStrokes = false
        overlay.floatingImage = nil
        self.baseDrawing = nil
        pendingTransform = .identity
    }

    // MARK: Geometry

    private var zoom: CGFloat { max(canvasView?.zoomScale ?? 1, 0.01) }
    /// Touch tolerance (22 screen points) in content coordinates.
    private var reach: CGFloat { 22 / zoom }

    private func contentPoint(_ screen: CGPoint) -> CGPoint {
        let offset = canvasView?.contentOffset ?? .zero
        return CGPoint(x: (screen.x + offset.x) / zoom, y: (screen.y + offset.y) / zoom)
    }

    private func screenPoint(_ content: CGPoint) -> CGPoint {
        let offset = canvasView?.contentOffset ?? .zero
        return CGPoint(x: content.x * zoom - offset.x, y: content.y * zoom - offset.y)
    }

    private func screenRect(_ content: CGRect) -> CGRect {
        guard !content.isNull else { return .null }
        let origin = screenPoint(content.origin)
        return CGRect(x: origin.x, y: origin.y, width: content.width * zoom, height: content.height * zoom)
    }

    /// Repositions the selection box after scrolling, zooming or a selection change.
    func refreshOverlay() {
        if isLiftingStrokes {
            overlay.floatingFrame = screenRect(liftedImageBounds.applying(pendingTransform))
            overlay.selectionFrame = screenRect(baseBounds.applying(pendingTransform))
        } else {
            overlay.selectionFrame = hasSelection ? screenRect(selectionBounds) : .null
        }
        if case .lassoing(let points) = interaction {
            overlay.lassoPoints = points.map(screenPoint)
        }
    }
}

/// Draws the lasso outline, the selection box with its eight handles, and the lifted strokes
/// while they are being dragged. Never intercepts touches.
final class SelectionOverlayView: UIView {
    var lassoPoints: [CGPoint] = [] {
        didSet { updateLasso() }
    }

    /// Selection box in this view's coordinates; `.null` hides it.
    var selectionFrame: CGRect = .null {
        didSet { if selectionFrame != oldValue { updateSelection() } }
    }

    var floatingImage: UIImage? {
        didSet {
            imageView.image = floatingImage
            imageView.isHidden = floatingImage == nil
        }
    }

    var floatingFrame: CGRect = .null {
        didSet { if !floatingFrame.isNull { imageView.frame = floatingFrame } }
    }

    var hasContent: Bool { !selectionFrame.isNull || !lassoPoints.isEmpty }

    private let imageView = UIImageView()
    private let lassoLayer = CAShapeLayer()
    private let boxLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        imageView.isHidden = true
        addSubview(imageView)

        let tint = UIColor.systemBlue
        lassoLayer.fillColor = tint.withAlphaComponent(0.06).cgColor
        lassoLayer.strokeColor = tint.cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 4]
        boxLayer.fillColor = tint.withAlphaComponent(0.07).cgColor
        boxLayer.strokeColor = tint.cgColor
        boxLayer.lineWidth = 1.5
        boxLayer.lineDashPattern = [6, 4]
        handleLayer.fillColor = UIColor.white.cgColor
        handleLayer.strokeColor = tint.cgColor
        handleLayer.lineWidth = 2
        handleLayer.shadowColor = UIColor.black.cgColor
        handleLayer.shadowOpacity = 0.2
        handleLayer.shadowRadius = 2
        handleLayer.shadowOffset = .zero
        [lassoLayer, boxLayer, handleLayer].forEach(layer.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateLasso() {
        guard lassoPoints.count > 1 else {
            lassoLayer.path = nil
            return
        }
        let path = CGMutablePath()
        path.addLines(between: lassoPoints)
        path.closeSubpath()
        withoutAnimation { lassoLayer.path = path }
    }

    private func updateSelection() {
        withoutAnimation {
            guard !selectionFrame.isNull else {
                boxLayer.path = nil
                handleLayer.path = nil
                return
            }
            boxLayer.path = CGPath(rect: selectionFrame, transform: nil)
            let handles = CGMutablePath()
            for handle in LassoSelectionController.Handle.allCases {
                let center = handle.point(in: selectionFrame)
                let radius: CGFloat = handle.isCorner ? 7 : 5.5
                handles.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
            }
            handleLayer.path = handles
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
