import UIKit

/// Haptic feedback for Apple Pencil gestures and palette picks.
///
/// iPad has no Taptic Engine. On iPadOS 17.5+, canvas feedback (`UICanvasFeedbackGenerator`) is the
/// type that plays through Apple Pencil Pro on a compatible iPad; impact and selection feedback are
/// triggered as well for hardware that supports them. Following Apple's "Playing haptic feedback in
/// your app" guidance, every event goes to the relevant generators without device checks, and the
/// system ignores whatever the current hardware can't play.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    var isEnabled = true

    private weak var hostView: UIView?
    private var canvasGenerator: UICanvasFeedbackGenerator?
    private var impactGenerator: UIImpactFeedbackGenerator?
    private var selectionGenerator: UISelectionFeedbackGenerator?

    private init() {}

    /// Generators are attached to the canvas so the system can route feedback to the pencil in use.
    func attach(to view: UIView) {
        hostView = view
        canvasGenerator = UICanvasFeedbackGenerator(view: view)
        impactGenerator = UIImpactFeedbackGenerator(style: .medium, view: view)
        selectionGenerator = UISelectionFeedbackGenerator(view: view)
        canvasGenerator?.prepare()
        impactGenerator?.prepare()
    }

    func detach(from view: UIView) {
        guard hostView === view else { return }
        hostView = nil
        canvasGenerator = nil
        impactGenerator = nil
        selectionGenerator = nil
    }

    /// A double-tap or squeeze finished. `location` is in the host view's coordinate space.
    func gestureCompleted(_ outcome: PencilGestureOutcome, at location: CGPoint?) {
        guard isEnabled, outcome != .ignored, let point = point(for: location) else { return }
        canvasGenerator?.alignmentOccurred(at: point)
        impactGenerator?.impactOccurred(intensity: outcome == .toolChanged ? 1.0 : 0.65, at: point)
        canvasGenerator?.prepare()
        impactGenerator?.prepare()
    }

    /// A tool, color or width was picked in the radial palette.
    func selectionChanged(at location: CGPoint? = nil) {
        guard isEnabled, let point = point(for: location) else { return }
        canvasGenerator?.alignmentOccurred(at: point)
        selectionGenerator?.selectionChanged(at: point)
    }

    private func point(for location: CGPoint?) -> CGPoint? {
        if let location { return location }
        guard let hostView else { return nil }
        return CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
    }
}
