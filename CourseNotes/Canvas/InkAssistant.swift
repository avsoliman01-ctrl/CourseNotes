import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Observes the touch that is drawing a stroke without ever recognizing a gesture itself.
///
/// It stays in `.possible` for the whole touch, never prevents and is never prevented, and does not
/// delay or cancel touches, so PencilKit's own drawing recognizer behaves exactly as if this weren't
/// attached. (A long-press recognizer would steal or delay the stroke; this cannot.)
final class StrokeObserverGestureRecognizer: UIGestureRecognizer {
    /// Locations are in the attached view's coordinate space.
    var onBegan: ((CGPoint) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onEnded: ((_ cancelled: Bool) -> Void)?

    private var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        onBegan?(touch.location(in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        onMoved?(trackedTouch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        self.trackedTouch = nil
        onEnded?(cancelled)
        state = .failed
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Drawing intelligence layered on top of PencilKit:
///
/// - **Hold to correct a shape.** Draw a rough shape and keep the pencil still for half a second.
///   The stroke is classified geometrically; if it is confidently a line, ellipse or polygon, a
///   clean preview appears, and when the pencil lifts the rough stroke is replaced by real ink in
///   that shape. Anything uncertain is left exactly as drawn.
/// - **Handwriting smoothing.** When the pencil pauses, strokes written since the last pause are
///   gently smoothed (see `StrokeSmoother`).
///
/// Both edits are applied only while no stroke is in progress and each is its own undo step, so
/// Undo first restores what was actually drawn.
@MainActor
final class InkAssistant: NSObject, UIGestureRecognizerDelegate {
    static let holdDuration: TimeInterval = 0.5
    /// How far (screen points) the pencil may drift and still count as held still.
    static let holdTolerance: CGFloat = 6

    var isShapeHoldEnabled = true
    var smoothing: SmoothingStrength = .off
    var allowsFingerInput = false
    /// Only inking tools get assistance; the eraser and lasso never do.
    var isInkingToolActive = true
    var previewColor: UIColor = .black
    var previewWidth: CGFloat = 3

    /// Called after this assistant has written a corrected drawing to the canvas.
    var onCommit: (() -> Void)?
    /// Called with a location in the canvas's frame when a held shape is recognized.
    var onShapeRecognized: ((CGPoint) -> Void)?

    /// True while this assistant is the one writing to `canvasView.drawing`.
    private(set) var isApplyingEdit = false

    private weak var canvasView: PKCanvasView?
    private let observer = StrokeObserverGestureRecognizer()
    private let previewLayer = CAShapeLayer()

    private var isTouchDown = false
    private var lastTouchEnd: Date = .distantPast
    /// The stroke in progress, in canvas content coordinates.
    private var samples: [CGPoint] = []
    private var restAnchor: CGPoint = .zero
    private var holdTimer: Timer?
    private var recognition: (shape: RecognizedShape, holdPoint: CGPoint)?
    /// Recognized shape (after any adjustment) waiting for PencilKit to commit the rough stroke.
    private var pendingShape: RecognizedShape?
    private var pendingShapeExpiry: DispatchWorkItem?

    private var unsmoothedIndices: [Int] = []
    private var smoothingWork: DispatchWorkItem?

    init(canvasView: PKCanvasView, overlayLayer: CALayer) {
        self.canvasView = canvasView
        super.init()

        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.delegate = self
        observer.onBegan = { [weak self] location in self?.touchBegan(at: location) }
        observer.onMoved = { [weak self] location in self?.touchMoved(to: location) }
        observer.onEnded = { [weak self] cancelled in self?.touchEnded(cancelled: cancelled) }
        canvasView.addGestureRecognizer(observer)

        previewLayer.fillColor = UIColor.clear.cgColor
        previewLayer.lineCap = .round
        previewLayer.lineJoin = .round
        previewLayer.shadowColor = UIColor.systemBlue.cgColor
        previewLayer.shadowOpacity = 0.7
        previewLayer.shadowRadius = 5
        previewLayer.shadowOffset = .zero
        previewLayer.isHidden = true
        overlayLayer.addSublayer(previewLayer)
    }

    // MARK: Canvas events (from the coordinator)

    /// PencilKit just committed a new ink stroke at `index`.
    func strokeAdded(at index: Int) {
        // A stroke that reappears through Redo was not just written; leave it exactly as it is.
        guard isTouchDown || Date().timeIntervalSince(lastTouchEnd) < 1 else {
            pendingShape = nil
            return
        }
        if let shape = pendingShape {
            pendingShape = nil
            pendingShapeExpiry?.cancel()
            // Next run-loop turn: outside PencilKit's callback and in its own undo group,
            // so one Undo reverts the correction and reveals the stroke as drawn.
            DispatchQueue.main.async { [weak self] in
                self?.replaceStroke(at: index, with: shape)
            }
            return
        }
        guard smoothing != .off else { return }
        unsmoothedIndices.append(index)
        scheduleSmoothing()
    }

    /// The drawing changed some other way (erase, undo, lasso edit): stroke indices are no longer valid.
    func resetPending() {
        unsmoothedIndices = []
        smoothingWork?.cancel()
        pendingShape = nil
        pendingShapeExpiry?.cancel()
        hidePreview()
    }

    // MARK: Hold detection

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard isInkingToolActive, isShapeHoldEnabled || smoothing != .off else { return false }
        return touch.type == .pencil || (allowsFingerInput && touch.type == .direct)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private var zoom: CGFloat { max(canvasView?.zoomScale ?? 1, 0.01) }

    /// A location in the scroll view's coordinate space already includes the scroll offset.
    private func contentPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x / zoom, y: location.y / zoom)
    }

    private func touchBegan(at location: CGPoint) {
        isTouchDown = true
        smoothingWork?.cancel()
        recognition = nil
        pendingShape = nil
        pendingShapeExpiry?.cancel()
        hidePreview()
        let point = contentPoint(location)
        samples = [point]
        restAnchor = point
        restartHoldTimer()
    }

    private func touchMoved(to location: CGPoint) {
        let point = contentPoint(location)
        samples.append(point)

        if let recognition {
            // Still holding after recognition: keep shaping the result.
            pendingShape = recognition.shape.adjusted(holdPoint: recognition.holdPoint, pencil: point)
            updatePreview()
        } else if hypot(point.x - restAnchor.x, point.y - restAnchor.y) > Self.holdTolerance / zoom {
            restAnchor = point
            restartHoldTimer()
        }
    }

    private func touchEnded(cancelled: Bool) {
        isTouchDown = false
        if !cancelled { lastTouchEnd = Date() }
        holdTimer?.invalidate()
        holdTimer = nil
        samples = []
        recognition = nil

        if cancelled {
            pendingShape = nil
            hidePreview()
        } else if pendingShape != nil {
            // If PencilKit never commits this stroke, don't leave a correction waiting for the next one.
            let expiry = DispatchWorkItem { [weak self] in
                self?.pendingShape = nil
                self?.hidePreview()
            }
            pendingShapeExpiry = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: expiry)
        }
        if !unsmoothedIndices.isEmpty { scheduleSmoothing() }
    }

    private func restartHoldTimer() {
        holdTimer?.invalidate()
        guard isShapeHoldEnabled else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pencilHeldStill()
            }
        }
    }

    private func pencilHeldStill() {
        guard isTouchDown, recognition == nil, let holdPoint = samples.last else { return }
        // Drop the jitter recorded while the pencil was resting.
        let tolerance = Self.holdTolerance / zoom
        var stroke = samples
        while stroke.count > 2, let last = stroke.last,
              hypot(last.x - holdPoint.x, last.y - holdPoint.y) <= tolerance,
              hypot(stroke[stroke.count - 2].x - holdPoint.x, stroke[stroke.count - 2].y - holdPoint.y) <= tolerance {
            stroke.removeLast()
        }
        guard let shape = ShapeRecognizer.recognize(stroke) else { return }

        recognition = (shape, holdPoint)
        pendingShape = shape
        updatePreview()
        if let canvasView {
            onShapeRecognized?(CGPoint(x: holdPoint.x * zoom - canvasView.contentOffset.x,
                                       y: holdPoint.y * zoom - canvasView.contentOffset.y))
        }
    }

    // MARK: Preview

    private func updatePreview() {
        guard let shape = pendingShape, let canvasView else {
            hidePreview()
            return
        }
        let offset = canvasView.contentOffset
        let points = shape.outline(spacing: 8).map {
            CGPoint(x: $0.point.x * zoom - offset.x, y: $0.point.y * zoom - offset.y)
        }
        guard points.count > 1 else { return }
        let path = CGMutablePath()
        path.addLines(between: points)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.path = path
        previewLayer.strokeColor = previewColor.cgColor
        previewLayer.lineWidth = max(2, previewWidth * zoom)
        previewLayer.isHidden = false
        CATransaction.commit()
    }

    private func hidePreview() {
        guard !previewLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.isHidden = true
        previewLayer.path = nil
        CATransaction.commit()
    }

    // MARK: Edits

    private func replaceStroke(at index: Int, with shape: RecognizedShape) {
        defer { hidePreview() }
        guard let canvasView, !isTouchDown else { return }
        let drawing = canvasView.drawing
        var strokes = drawing.strokes
        guard index < strokes.count else { return }
        strokes[index] = ShapeStrokeBuilder.stroke(for: shape, replacing: strokes[index])
        commit(PKDrawing(strokes: strokes), from: drawing, actionName: "Shape Correction")
    }

    private func scheduleSmoothing() {
        smoothingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applySmoothing()
        }
        smoothingWork = work
        // Long enough that writing a word isn't interrupted, short enough to feel immediate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func applySmoothing() {
        // Never touch the drawing while a stroke is in progress; try again at the next pause.
        guard let canvasView, !isTouchDown else { return }
        let indices = unsmoothedIndices
        unsmoothedIndices = []
        guard smoothing != .off, !indices.isEmpty else { return }

        let drawing = canvasView.drawing
        var strokes = drawing.strokes
        var changed = false
        for index in indices where index < strokes.count {
            if let smoothed = StrokeSmoother.smoothed(strokes[index], strength: smoothing) {
                strokes[index] = smoothed
                changed = true
            }
        }
        if changed {
            commit(PKDrawing(strokes: strokes), from: drawing, actionName: "Smooth Handwriting")
        }
    }

    /// Writes `newDrawing` to the canvas and registers an undo step that restores `oldDrawing`.
    private func commit(_ newDrawing: PKDrawing, from oldDrawing: PKDrawing, actionName: String) {
        guard let canvasView else { return }
        if let undoManager = canvasView.undoManager {
            undoManager.registerUndo(withTarget: self) { assistant in
                MainActor.assumeIsolated {
                    // Runs for undo; the nested commit registers the matching redo.
                    guard let current = assistant.canvasView?.drawing else { return }
                    assistant.resetPending()
                    assistant.commit(oldDrawing, from: current, actionName: actionName)
                }
            }
            undoManager.setActionName(actionName)
        }
        isApplyingEdit = true
        canvasView.drawing = newDrawing
        isApplyingEdit = false
        onCommit?()
    }
}
