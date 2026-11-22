import PencilKit
import UIKit

/// Renders notes outside the live canvas: dashboard thumbnails and PDF export.
///
/// Everything here is safe to call off the main thread. `PKDrawing.image(from:scale:)` is
/// thread-safe (Apple's PencilKit sample renders thumbnails on a background queue the same way).
enum NoteRenderer {
    static let thumbnailSize = CGSize(width: 360, height: 360 / CanvasMetrics.thumbnailAspectRatio)

    /// Paper + ink for the top of the page, matching what the canvas shows when first opened.
    /// Thumbnails are always light; the dashboard inverts them for display on dark paper.
    static func thumbnail(for drawing: PKDrawing, template: PaperTemplate, size: CGSize = thumbnailSize) -> UIImage {
        let scale = size.width / CanvasMetrics.pageWidth
        let contentRect = CGRect(x: 0, y: 0, width: CanvasMetrics.pageWidth, height: size.height / scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true

        let ink = inkImage(drawing, in: contentRect, scale: scale * format.scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            PaperColors.light.paper.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            template.draw(in: cg, contentRect: contentRect, zoomScale: scale)
            cg.restoreGState()

            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Writes the note as a multi-page PDF (US Letter proportions) to a temporary file,
    /// on white or black paper regardless of how the note is shown on screen.
    static func pdf(for drawing: PKDrawing, template: PaperTemplate, title: String,
                    appearance: PaperAppearance = .light) throws -> URL {
        let pageSize = CGSize(width: CanvasMetrics.pageWidth, height: CanvasMetrics.pageHeight)
        let inkBottom = drawing.bounds.isNull ? 0 : drawing.bounds.maxY
        let pageCount = max(1, Int(ceil(inkBottom / pageSize.height)))

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "CourseNotes"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        let url = FileManager.default.temporaryDirectory
            .appending(path: fileName(for: title))
            .appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: url)

        try renderer.writePDF(to: url) { context in
            for page in 0..<pageCount {
                autoreleasepool {
                    context.beginPage()
                    let cg = context.cgContext
                    let pageRect = CGRect(origin: CGPoint(x: 0, y: CGFloat(page) * pageSize.height), size: pageSize)

                    appearance.colors.paper.setFill()
                    cg.fill(CGRect(origin: .zero, size: pageSize))

                    cg.saveGState()
                    cg.translateBy(x: 0, y: -pageRect.minY)
                    template.draw(in: cg, contentRect: pageRect, zoomScale: 1, colors: appearance.colors)
                    cg.restoreGState()

                    inkImage(drawing, in: pageRect, scale: 2, appearance: appearance).draw(in: CGRect(origin: .zero, size: pageSize))
                }
            }
        }
        return url
    }

    /// File-system-safe version of a note title.
    static func fileName(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = title.components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled Note" : cleaned
    }

    /// `PKDrawing.image` adapts ink to the current trait collection, so render under the paper's
    /// appearance: black ink stays black on white paper and becomes white on black paper.
    private static func inkImage(_ drawing: PKDrawing, in rect: CGRect, scale: CGFloat,
                                 appearance: PaperAppearance = .light) -> UIImage {
        var image = UIImage()
        appearance.traitCollection.performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        return image
    }
}
