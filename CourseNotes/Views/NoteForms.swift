import SwiftUI

/// Course (grouped by semester) and module pickers. Keeps the module valid when the course changes.
/// A nil module means "create a Notes module on save" (for courses whose modules were all removed).
struct CourseModulePicker: View {
    @Environment(CourseDataManager.self) private var data
    @Binding var courseID: UUID?
    @Binding var moduleID: UUID?

    var body: some View {
        Picker("Course", selection: $courseID) {
            ForEach(data.sortedSemesters) { semester in
                Section(semester.name) {
                    ForEach(data.courses(in: semester.id)) { course in
                        Text(course.displayName).tag(Optional(course.id))
                    }
                }
            }
        }

        Picker("Module", selection: $moduleID) {
            if let courseID {
                ForEach(data.modules(in: courseID)) { module in
                    Label(module.name, systemImage: module.kind.symbolName).tag(Optional(module.id))
                }
            }
            if moduleID == nil {
                Text("Notes (new module)").tag(UUID?.none)
            }
        }
        .disabled(courseID == nil)
        .onChange(of: courseID) { _, newCourseID in
            if let moduleID, data.module(id: moduleID)?.courseID == newCourseID { return }
            moduleID = newCourseID.flatMap { data.modules(in: $0).first?.id }
        }
    }
}

struct NewNoteSheet: View {
    let onCreate: (UUID) -> Void

    @Environment(CourseDataManager.self) private var data
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.defaultTemplate) private var defaultTemplate: PaperTemplate = .collegeRuled
    @State private var courseID: UUID?
    @State private var moduleID: UUID?
    @State private var title = ""
    @State private var tagsText = ""
    /// nil until the user picks one, so the default from Settings applies.
    @State private var template: PaperTemplate?

    init(courseID: UUID?, moduleID: UUID?, onCreate: @escaping (UUID) -> Void) {
        self.onCreate = onCreate
        _courseID = State(initialValue: courseID)
        _moduleID = State(initialValue: moduleID)
    }

    var body: some View {
        NavigationStack {
            Form {
                if data.courses.isEmpty {
                    ContentUnavailableView("No Courses Yet", systemImage: "books.vertical",
                                           description: Text("Add a semester and a course from the sidebar first."))
                } else {
                    Section("Title") {
                        TextField(suggestedTitle, text: $title)
                    }
                    Section("Location") {
                        CourseModulePicker(courseID: $courseID, moduleID: $moduleID)
                    }
                    Section {
                        TextField("lecture, midterm, chapter-3", text: $tagsText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Tags")
                    } footer: {
                        Text("Optional. Separate tags with commas.")
                    }
                    Section("Paper") {
                        TemplatePicker(selection: templateBinding)
                    }
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(courseID == nil)
                }
            }
            .onAppear(perform: resolveDefaults)
        }
    }

    private var templateBinding: Binding<PaperTemplate> {
        Binding(get: { template ?? defaultTemplate }, set: { template = $0 })
    }

    private var suggestedTitle: String {
        moduleID.map { data.suggestedTitle(for: $0) } ?? "Untitled Note"
    }

    /// Fills in a sensible course and module when the sheet wasn't opened from one.
    private func resolveDefaults() {
        if courseID.flatMap({ data.course(id: $0) }) == nil {
            courseID = data.sortedSemesters.lazy.compactMap { data.courses(in: $0.id).first }.first?.id
        }
        if let courseID, moduleID.flatMap({ data.module(id: $0) })?.courseID != courseID {
            moduleID = data.modules(in: courseID).first?.id
        }
    }

    private func create() {
        guard let courseID else { return }
        let targetModuleID = moduleID ?? data.addModule(courseID: courseID, name: "", kind: .custom).id
        let note = data.createNote(in: targetModuleID, title: title, template: template ?? defaultTemplate,
                                   tags: TagFormatter.parse(tagsText))
        dismiss()
        onCreate(note.id)
    }
}

/// Rename, tag, move and change the paper of an existing note.
struct NoteDetailsSheet: View {
    let noteID: UUID

    @Environment(CourseDataManager.self) private var data
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var tagsText = ""
    @State private var courseID: UUID?
    @State private var moduleID: UUID?
    @State private var template: PaperTemplate = .blank
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Group {
                if let note = data.note(id: noteID) {
                    Form {
                        Section("Title") {
                            TextField("Title", text: $title)
                        }
                        Section {
                            TextField("lecture, midterm, chapter-3", text: $tagsText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } header: {
                            Text("Tags")
                        } footer: {
                            Text("Separate tags with commas.")
                        }
                        Section("Location") {
                            CourseModulePicker(courseID: $courseID, moduleID: $moduleID)
                        }
                        Section("Paper") {
                            TemplatePicker(selection: $template)
                        }
                        Section {
                            LabeledContent("Created", value: note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("Modified", value: note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .onAppear { load(note) }
                } else {
                    ContentUnavailableView("Note Not Found", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle("Note Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(data.note(id: noteID) == nil || courseID == nil)
                }
            }
        }
    }

    private func load(_ note: NoteDocument) {
        guard !didLoad else { return }
        didLoad = true
        title = note.title
        tagsText = note.tags.joined(separator: ", ")
        template = note.template
        // Module first, so the picker's course-change handler sees a module that already matches.
        moduleID = note.moduleID
        courseID = data.module(id: note.moduleID)?.courseID
    }

    private func save() {
        guard let note = data.note(id: noteID), let courseID else {
            dismiss()
            return
        }
        if title.trimmed != note.title { data.renameNote(id: noteID, to: title.trimmed) }

        let tags = TagFormatter.parse(tagsText)
        if tags != note.tags { data.setTags(tags, for: noteID) }

        if template != note.template { data.setTemplate(template, for: noteID) }

        let targetModuleID = moduleID ?? data.addModule(courseID: courseID, name: "", kind: .custom).id
        if targetModuleID != note.moduleID { data.moveNote(id: noteID, toModule: targetModuleID) }
        dismiss()
    }
}

// MARK: - Paper template picker

struct TemplatePicker: View {
    @Binding var selection: PaperTemplate

    var body: some View {
        HStack(spacing: 16) {
            ForEach(PaperTemplate.allCases) { template in
                Button {
                    selection = template
                } label: {
                    VStack(spacing: 6) {
                        TemplateSwatch(template: template)
                            .frame(width: 64, height: 82)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(template == selection ? Color.accentColor : Color.secondary.opacity(0.3),
                                                  lineWidth: template == selection ? 3 : 1)
                            )
                        Text(template.displayName)
                            .font(.caption)
                            .foregroundStyle(template == selection ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(template.displayName)
                .accessibilityAddTraits(template == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}

/// Miniature of a paper template, drawn with the same routine as the canvas.
struct TemplateSwatch: View {
    let template: PaperTemplate

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                // Show the top-left quarter of the page so lines are big enough to read.
                let contentWidth = CanvasMetrics.pageWidth / 4
                let scale = size.width / contentWidth
                cg.scaleBy(x: scale, y: scale)
                template.draw(in: cg, contentRect: CGRect(x: 0, y: 0, width: contentWidth, height: size.height / scale),
                              zoomScale: scale)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
