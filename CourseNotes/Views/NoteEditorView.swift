import PencilKit
import SwiftUI

/// Loads a note's ink, autosaves edits, and exports PDFs.
@MainActor
@Observable
final class NoteEditorViewModel {
    let noteID: UUID
    private(set) var initialDrawing: PKDrawing?
    private(set) var isExporting = false
    var shareItem: ShareItem?

    private let data: CourseDataManager
    @ObservationIgnored private var pendingDrawing: PKDrawing?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    init(noteID: UUID, data: CourseDataManager) {
        self.noteID = noteID
        self.data = data
    }

    func load() async {
        guard initialDrawing == nil else { return }
        initialDrawing = await data.loadDrawing(for: noteID)
    }

    /// Called after every change; writes 1.5 s after the user stops drawing.
    func drawingChanged(_ drawing: PKDrawing) {
        pendingDrawing = drawing
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Flushes unsaved ink immediately (closing the note, app going to the background).
    func saveNow() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let drawing = pendingDrawing else { return }
        pendingDrawing = nil
        data.saveDrawing(drawing, for: noteID)
    }

    func exportPDF(currentDrawing: PKDrawing?) async {
        guard !isExporting, let note = data.note(id: noteID) else { return }
        isExporting = true
        defer { isExporting = false }

        let drawing = currentDrawing ?? pendingDrawing ?? initialDrawing ?? PKDrawing()
        let template = note.template
        let title = note.displayTitle
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try NoteRenderer.pdf(for: drawing, template: template, title: title)
            }.value
            shareItem = ShareItem(url: url)
        } catch {
            data.lastErrorMessage = "Couldn't export “\(title)” as a PDF. \(error.localizedDescription)"
        }
    }
}

/// Full-width canvas workspace: floating tool palette, squeeze palette, gesture toasts,
/// paper template and export controls.
struct NoteEditorView: View {
    @Environment(CourseDataManager.self) private var data
    @Environment(ApplePencilManager.self) private var pencil
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: NoteEditorViewModel
    @State private var canvasController = CanvasController()
    @State private var showingDetails = false

    init(noteID: UUID, dataManager: CourseDataManager) {
        _viewModel = State(initialValue: NoteEditorViewModel(noteID: noteID, data: dataManager))
    }

    var body: some View {
        Group {
            if let note = data.note(id: viewModel.noteID) {
                editor(for: note)
            } else {
                ContentUnavailableView("Note Not Found", systemImage: "doc.questionmark",
                                       description: Text("This note may have been deleted."))
            }
        }
        .task {
            await viewModel.load()
        }
        .onDisappear {
            viewModel.saveNow()
            pencil.dismissRadialPalette()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.saveNow() }
        }
    }

    private func editor(for note: NoteDocument) -> some View {
        ZStack(alignment: .top) {
            canvas(for: note)

            ToolPaletteView(controller: canvasController)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if let toast = pencil.toast {
                PencilToastView(toast: toast)
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(1.4))
                        pencil.clearToast(id: toast.id)
                    }
            }
        }
        .animation(.snappy(duration: 0.25), value: pencil.toast)
        .navigationTitle(titleBinding(for: note))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar { toolbar(for: note) }
        .sheet(isPresented: $showingDetails) {
            NoteDetailsSheet(noteID: note.id)
        }
        .sheet(item: $viewModel.shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
    }

    @ViewBuilder
    private func canvas(for note: NoteDocument) -> some View {
        if let drawing = viewModel.initialDrawing {
            PencilCanvasView(
                initialDrawing: drawing,
                template: note.template,
                tool: pencil.currentConfiguration,
                drawingPolicy: pencil.preferences.fingerDrawing.drawingPolicy,
                showsHoverReticle: pencil.preferences.showsHoverReticle,
                controller: canvasController,
                pencil: pencil,
                onDrawingChange: viewModel.drawingChanged
            )
            .id(note.id)
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay {
                // Same coordinate space as the canvas container, so the squeeze palette
                // opens exactly under the hovering pencil tip.
                if let palette = pencil.radialPalette {
                    RadialPaletteView(anchor: palette.anchor)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.28, bounce: 0.25), value: pencil.radialPalette)
        } else {
            ProgressView("Opening note…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(for note: NoteDocument) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Paper", selection: templateBinding(for: note)) {
                    ForEach(PaperTemplate.allCases) { template in
                        Label(template.displayName, systemImage: template.symbolName).tag(template)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Paper", systemImage: note.template.symbolName)
            }

            Button {
                canvasController.toggleRuler()
            } label: {
                Label("Ruler", systemImage: canvasController.isRulerActive ? "ruler.fill" : "ruler")
            }

            Button {
                data.toggleFavorite(id: note.id)
            } label: {
                Label(note.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: note.isFavorite ? "star.fill" : "star")
            }

            Menu {
                Button {
                    showingDetails = true
                } label: {
                    Label("Rename, Tag or Move…", systemImage: "info.circle")
                }
                Button {
                    canvasController.zoomToFitWidth()
                } label: {
                    Label("Fit Page Width", systemImage: "arrow.left.and.right.square")
                }
                Divider()
                Button {
                    Task { await viewModel.exportPDF(currentDrawing: canvasController.currentDrawing) }
                } label: {
                    Label("Export PDF…", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.isExporting)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func titleBinding(for note: NoteDocument) -> Binding<String> {
        Binding(
            get: { data.note(id: note.id)?.title ?? note.title },
            set: { data.renameNote(id: note.id, to: $0) }
        )
    }

    private func templateBinding(for note: NoteDocument) -> Binding<PaperTemplate> {
        Binding(
            get: { data.note(id: note.id)?.template ?? note.template },
            set: { data.setTemplate($0, for: note.id) }
        )
    }
}
