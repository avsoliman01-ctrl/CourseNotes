import SwiftUI
import Vision

/// Contextual bar shown while the lasso has a selection: recolor, duplicate, recognize text, delete.
/// Moving and resizing happen directly on the canvas (drag inside the box, or drag its handles).
struct SelectionToolbarView: View {
    let controller: CanvasController

    @State private var customColor = Color.blue
    @State private var recognition: RecognitionRequest?

    var body: some View {
        HStack(spacing: 6) {
            Text(pluralize(controller.selectionCount, "stroke"))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 6)

            Divider().frame(height: 24)

            ForEach(InkPalette.pen, id: \.self) { color in
                Button {
                    controller.recolorSelection(color)
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                        .frame(width: 32, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recolor selection")
            }
            ColorPicker("Custom Color", selection: customColorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34, height: 38)

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
        .sheet(item: $recognition) { request in
            TextRecognitionSheet(image: request.image)
        }
    }

    /// Every value the system color picker reports is applied live; the selection controller folds
    /// a continuous drag into a single undo step.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { customColor },
            set: { newColor in
                customColor = newColor
                controller.recolorSelection(RGBAColor(UIColor(newColor)))
            }
        )
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
