import SwiftUI
import Vision

/// Contextual bar shown while the lasso has a selection: recolor or fill, line style, duplicate,
/// recognize text, delete. Moving and resizing happen directly on the canvas (drag inside the box,
/// or drag its handles).
struct SelectionToolbarView: View {
    let controller: CanvasController

    /// What a color tap changes: the strokes themselves, or the inside of closed shapes.
    private enum ColorTarget: Hashable {
        case ink, fill
    }

    @Environment(ApplePencilManager.self) private var pencil
    @Environment(\.paperAppearance) private var paperAppearance
    @State private var target: ColorTarget = .ink
    @State private var fillStyle: FillStyle = .solid
    @State private var customColor = Color.blue
    /// Fills are rebuilt per change, so colors from the system picker are applied once it settles.
    @State private var pendingFillColor: RGBAColor?
    @State private var notice: String?
    @State private var recognition: RecognitionRequest?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(swatchLimit: nil)
            bar(swatchLimit: 3)
        }
        .sheet(item: $recognition) { request in
            TextRecognitionSheet(image: request.image)
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            notice = nil
        }
        .task(id: pendingFillColor) {
            guard let color = pendingFillColor else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            pendingFillColor = nil
            apply(color)
        }
    }

    private func bar(swatchLimit: Int?) -> some View {
        let swatches = pencil.penSwatches
        let shown = swatchLimit.map { Array(swatches.prefix($0)) } ?? swatches

        return HStack(spacing: 6) {
            Text(notice ?? pluralize(controller.selectionCount, "stroke"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(notice == nil ? Color.primary : Color.orange)
                .monospacedDigit()
                .padding(.horizontal, 6)

            Divider().frame(height: 24)

            Picker("Color Changes", selection: $target) {
                Text("Ink").tag(ColorTarget.ink)
                Text("Fill").tag(ColorTarget.fill)
            }
            .pickerStyle(.segmented)
            .frame(width: 104)
            .help("Ink recolors the strokes; Fill paints the inside of closed shapes")

            ForEach(Array(shown.enumerated()), id: \.offset) { _, color in
                Button {
                    apply(color)
                } label: {
                    Circle()
                        .fill(color.displayedColor(on: paperAppearance))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                        .frame(width: 32, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(target == .fill ? "Fill selection" : "Recolor selection")
            }
            ColorPicker("Custom Color", selection: customColorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34, height: 38)

            if target == .fill {
                Menu {
                    Picker("Fill Style", selection: $fillStyle) {
                        ForEach(FillStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        if !controller.removeFillFromSelection() { notice = "No fill to remove" }
                    } label: {
                        Label("Remove Fill", systemImage: "drop.triangle")
                    }
                } label: {
                    barIcon("drop.fill")
                }
                .help("Fill style")
                .accessibilityLabel("Fill options")
            }

            Menu {
                ForEach(StrokeLineStyle.allCases) { style in
                    Button(style.title) {
                        if !controller.setSelectionLineStyle(style) { notice = "Already \(style.title.lowercased())" }
                    }
                }
            } label: {
                barIcon("square.dashed")
            }
            .help("Line style: solid, dashed or dotted")
            .accessibilityLabel("Line style")

            Divider().frame(height: 24)

            barButton("Duplicate", systemImage: "plus.square.on.square") {
                controller.duplicateSelection()
            }
            barButton("Recognize Text", systemImage: "text.viewfinder") {
                if let image = controller.selectionImage() {
                    recognition = RecognitionRequest(image: image)
                }
            }
            barButton("Delete", systemImage: "trash", role: .destructive) {
                controller.deleteSelection()
            }

            Divider().frame(height: 24)

            Button("Done") {
                controller.clearSelection()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .fixedSize()
    }

    private func apply(_ color: RGBAColor) {
        switch target {
        case .ink:
            controller.recolorSelection(color)
        case .fill:
            if !controller.fillSelection(color, style: fillStyle) {
                notice = "No closed shape"
            }
        }
    }

    /// Ink changes apply live (the selection controller folds a continuous drag into one undo step).
    /// Fills apply once the picker settles. Colors picked on dark paper are stored so they draw
    /// as they were seen.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { customColor },
            set: { newColor in
                customColor = newColor
                let stored = RGBAColor.stored(fromDisplayed: UIColor(newColor), on: paperAppearance)
                if target == .fill {
                    pendingFillColor = stored
                } else {
                    controller.recolorSelection(stored)
                }
            }
        )
    }

    private func barIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
    }

    private func barButton(_ title: String, systemImage: String, role: ButtonRole? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct RecognitionRequest: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// On-device handwriting recognition with Apple's Vision framework.
///
/// This reads handwriting; it never changes it. Vision returns its best guess at the words,
/// which is useful for copying text out of a note but is not reliable for mathematical notation
/// or diagrams.
enum HandwritingRecognizer {
    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

/// Lets the user review and correct recognized text before copying it. The ink is left untouched.
struct TextRecognitionSheet: View {
    let image: UIImage

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isRecognizing = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Selected Handwriting") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .frame(maxWidth: .infinity)
                }
                Section {
                    if isRecognizing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading handwriting…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextEditor(text: $text)
                            .frame(minHeight: 140)
                    }
                } header: {
                    Text("Recognized Text")
                } footer: {
                    Text(failure ?? "Review and correct the text, then copy it. Recognition runs on your iPad and leaves your handwriting unchanged.")
                }
            }
            .navigationTitle("Recognize Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        UIPasteboard.general.string = text
                        dismiss()
                    }
                    .disabled(isRecognizing || text.trimmed.isEmpty)
                }
            }
            .task {
                do {
                    text = try await HandwritingRecognizer.recognizeText(in: image)
                    if text.trimmed.isEmpty { failure = "No text was recognized in the selection." }
                } catch {
                    failure = "Recognition failed: \(error.localizedDescription)"
                }
                isRecognizing = false
            }
        }
    }
}
