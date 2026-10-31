import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// System share sheet (AirDrop, Files, Mail…) for exported PDFs and library backups.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        // Dismiss through SwiftUI so the sheet's item binding resets when sharing finishes.
        let dismiss = context.environment.dismiss
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in dismiss() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
