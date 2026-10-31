import PencilKit
import SwiftUI
import UIKit

/// Lets SwiftUI controls (undo/redo, ruler, zoom) drive the live canvas.
@MainActor
@Observable
final class CanvasController {
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var isRulerActive = false

    @ObservationIgnored fileprivate weak var container: CanvasContainerView?

    /// The ink currently on screen, including strokes not yet autosaved.
    var currentDrawing: PKDrawing? { container?.canvasView.drawing }

    func undo() {
        container?.canvasView.undoManager?.undo()
        refreshUndoState()
    }

    func redo() {
        container?.canvasView.undoManager?.redo()
        refreshUndoState()
    }

    func toggleRuler() {
        guard let canvas = container?.canvasView else { return }
        canvas.isRulerActive.toggle()
        isRulerActive = canvas.isRulerActive
    }

    func zoomToFitWidth() {
        container?.zoomToFitWidth(animated: true)
    }

    fileprivate func refreshUndoState() {
        let undoManager = container?.canvasView.undoManager
        let undo = undoManager?.canUndo ?? false
        let redo = undoManager?.canRedo ?? false
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
    }
}

/// SwiftUI wrapper around `PKCanvasView`.
///
/// Handles drawing, Apple Pencil double-tap and squeeze (`UIPencilInteraction`), hover with tilt and
/// barrel roll (`UIHoverGestureRecognizer`), and haptic hooks. Tool state is owned by
/// `ApplePencilManager`; the parent passes the resolved `ToolConfiguration` in.
struct PencilCanvasView: UIViewRepresentable {
    let initialDrawing: PKDrawing
    let template: PaperTemplate
    let tool: ToolConfiguration
    let drawingPolicy: PKCanvasViewDrawingPolicy
    let showsHoverReticle: Bool
    let controller: CanvasController
    let pencil: ApplePencilManager
    let onDrawingChange: @MainActor (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> CanvasContainerView {
        let container = CanvasContainerView()
        let canvas = container.canvasView
        let coordinator = context.coordinator

        // Assign ink before the delegate so opening a note doesn't register as an edit.
        canvas.drawing = initialDrawing
        canvas.delegate = coordinator
        canvas.drawingPolicy = drawingPolicy
        container.template = template
        coordinator.container = container
        coordinator.apply(tool)

        // Double-tap (Apple Pencil 2 / Pro) and squeeze (Apple Pencil Pro). Attached to the
        // non-scrolling container so hover-pose locations are in the same space as SwiftUI overlays.
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = coordinator
        container.addInteraction(pencilInteraction)

        let hover = UIHoverGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleHover(_:)))
        container.addGestureRecognizer(hover)

        controller.container = container
        coordinator.observeUndo(of: canvas)
        HapticEngine.shared.attach(to: container)
        return container
    }

    func updateUIView(_ container: CanvasContainerView, context: Context) {
        context.coordinator.parent = self
        container.template = template
        context.coordinator.apply(tool)
        if container.canvasView.drawingPolicy != drawingPolicy {
            container.canvasView.drawingPolicy = drawingPolicy
        }
        if !showsHoverReticle {
            container.reticleView.hide()
        }
    }

    static func dismantleUIView(_ container: CanvasContainerView, coordinator: Coordinator) {
        coordinator.tearDown()
        HapticEngine.shared.detach(from: container)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var parent: PencilCanvasView
        weak var container: CanvasContainerView?

        private var appliedTool: ToolConfiguration?
        private var undoObservers: [NSObjectProtocol] = []
        /// Where the pencil is hovering right now (container coordinates), if it is.
        private var hoverLocation: CGPoint?

        init(parent: PencilCanvasView) {
            self.parent = parent
        }

        func apply(_ tool: ToolConfiguration) {
            guard tool != appliedTool, let container else { return }
            appliedTool = tool
            container.canvasView.tool = tool.pkTool
            container.reticleView.configure(for: tool)
        }

        func observeUndo(of canvasView: PKCanvasView) {
            guard let undoManager = canvasView.undoManager else { return }
            let names: [Notification.Name] = [
                .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange
            ]
            undoObservers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.parent.controller.refreshUndoState()
                    }
                }
            }
        }

        func tearDown() {
            undoObservers.forEach { NotificationCenter.default.removeObserver($0) }
            undoObservers.removeAll()
            container?.canvasView.undoManager?.removeAllActions()
            if parent.controller.container === container {
                parent.controller.container = nil
            }
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            container?.updateContentSize()
            parent.onDrawingChange(canvasView.drawing)
            parent.controller.refreshUndoState()
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            container?.reticleView.hide()
            // Starting to write dismisses the squeeze palette, like the system tool palette.
            parent.pencil.dismissRadialPalette()
        }

        // PKCanvasView is a UIScrollView; keep the paper template in step with scrolling and zooming.
        // (Don't implement viewForZooming(in:) — PKCanvasView supplies its own zooming view.)

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.syncPaperWithCanvas()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.syncPaperWithCanvas()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            container?.updateContentSize()
            container?.syncPaperWithCanvas()
        }

        // MARK: UIPencilInteractionDelegate (iPadOS 17.5+)

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            let location = tap.hoverPose?.location ?? hoverLocation
            let outcome = parent.pencil.handleDoubleTap(at: location)
            HapticEngine.shared.gestureCompleted(outcome, at: location)
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            // The hover pose lets the palette open right under the pencil tip.
            let location = squeeze.hoverPose?.location ?? hoverLocation
            let outcome = parent.pencil.handleSqueeze(Self.phase(of: squeeze), at: location)
            HapticEngine.shared.gestureCompleted(outcome, at: location)
        }

        private static func phase(of squeeze: UIPencilInteraction.Squeeze) -> PencilSqueezePhase {
            switch squeeze.phase {
            case .began: .began
            case .changed: .changed
            case .ended: .ended
            case .cancelled: .cancelled
            @unknown default: .cancelled
            }
        }

        // MARK: Hover (tilt, azimuth, barrel roll)

        @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard let container else { return }
            switch recognizer.state {
            case .began, .changed:
                // zOffset is 0 for a trackpad pointer and > 0 for a hovering Apple Pencil.
                guard recognizer.zOffset > 0 else {
                    hoverLocation = nil
                    container.reticleView.hide()
                    return
                }
                let location = recognizer.location(in: container)
                hoverLocation = location
                guard parent.showsHoverReticle, UIPencilInteraction.prefersHoverToolPreview else {
                    container.reticleView.hide()
                    return
                }
                container.reticleView.show(HoverReticleView.Pose(
                    location: location,
                    zOffset: recognizer.zOffset,
                    altitude: recognizer.altitudeAngle,
                    azimuth: recognizer.azimuthAngle(in: container),
                    roll: recognizer.rollAngle
                ))
            default:
                hoverLocation = nil
                container.reticleView.hide()
            }
        }
    }
}
