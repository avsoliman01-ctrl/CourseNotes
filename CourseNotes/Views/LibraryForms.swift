import SwiftUI

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// "1 note", "3 notes"
func pluralize(_ count: Int, _ noun: String) -> String {
    "\(count) \(count == 1 ? noun : noun + "s")"
}

// MARK: - Sheet routing

enum LibrarySheet: Identifiable {
    case newSemester
    case editSemester(Semester)
    case newCourse(semesterID: UUID?)
    case editCourse(Course)
    case newModule(courseID: UUID)
    case editModule(CourseModule)
    case newNote(courseID: UUID?, moduleID: UUID?)
    case noteDetails(noteID: UUID)
    case settings

    var id: String {
        switch self {
        case .newSemester: "newSemester"
        case .editSemester(let semester): "editSemester-\(semester.id)"
        case .newCourse(let semesterID): "newCourse-\(semesterID?.uuidString ?? "")"
        case .editCourse(let course): "editCourse-\(course.id)"
        case .newModule(let courseID): "newModule-\(courseID)"
        case .editModule(let module): "editModule-\(module.id)"
        case .newNote(let courseID, let moduleID): "newNote-\(courseID?.uuidString ?? "")-\(moduleID?.uuidString ?? "")"
        case .noteDetails(let noteID): "noteDetails-\(noteID)"
        case .settings: "settings"
        }
    }
}

struct LibrarySheetView: View {
    let sheet: LibrarySheet
    var onNoteCreated: (UUID) -> Void = { _ in }

    var body: some View {
        switch sheet {
        case .newSemester:
            SemesterFormView(semester: nil)
        case .editSemester(let semester):
            SemesterFormView(semester: semester)
        case .newCourse(let semesterID):
            CourseFormView(course: nil, semesterID: semesterID)
        case .editCourse(let course):
            CourseFormView(course: course, semesterID: course.semesterID)
        case .newModule(let courseID):
            ModuleFormView(module: nil, courseID: courseID)
        case .editModule(let module):
            ModuleFormView(module: module, courseID: module.courseID)
        case .newNote(let courseID, let moduleID):
            NewNoteSheet(courseID: courseID, moduleID: moduleID, onCreate: onNoteCreated)
        case .noteDetails(let noteID):
            NoteDetailsSheet(noteID: noteID)
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Deletion

enum DeletionTarget: Identifiable {
    case semester(Semester)
    case course(Course)
    case module(CourseModule)
    case note(NoteDocument)

    var id: UUID {
        switch self {
        case .semester(let semester): semester.id
        case .course(let course): course.id
        case .module(let module): module.id
        case .note(let note): note.id
        }
    }
}

private struct DeletionAlertModifier: ViewModifier {
    @Binding var target: DeletionTarget?
    let onDeleted: (DeletionTarget) -> Void

    @Environment(CourseDataManager.self) private var data

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented, presenting: target) { target in
            Button("Delete", role: .destructive) { delete(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(message(for: target))
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }

    private var title: String {
        switch target {
        case .semester(let semester)?: "Delete “\(semester.name)”?"
        case .course(let course)?: "Delete “\(course.shortName)”?"
        case .module(let module)?: "Delete “\(module.name)”?"
        case .note(let note)?: "Delete “\(note.displayTitle)”?"
        case nil: "Delete?"
        }
    }

    private func message(for target: DeletionTarget) -> String {
        switch target {
        case .semester(let semester):
            let courses = data.courses(in: semester.id)
            let notes = courses.reduce(0) { $0 + data.noteCount(inCourse: $1.id) }
            return "This permanently deletes \(pluralize(courses.count, "course")) and \(pluralize(notes, "note")), including all ink. This can't be undone."
        case .course(let course):
            return "This permanently deletes the course, its modules and \(pluralize(data.noteCount(inCourse: course.id), "note")). This can't be undone."
        case .module(let module):
            return "This permanently deletes \(pluralize(data.noteCount(inModule: module.id), "note")) in this module. This can't be undone."
        case .note:
            return "The note and its ink will be permanently deleted. This can't be undone."
        }
    }

    private func delete(_ target: DeletionTarget) {
        switch target {
        case .semester(let semester): data.deleteSemester(id: semester.id)
        case .course(let course): data.deleteCourse(id: course.id)
        case .module(let module): data.deleteModule(id: module.id)
        case .note(let note): data.deleteNote(id: note.id)
        }
        onDeleted(target)
    }
}

extension View {
    /// Confirms and performs a destructive delete, then reports what was deleted.
    func deletionAlert(_ target: Binding<DeletionTarget?>,
                       onDeleted: @escaping (DeletionTarget) -> Void = { _ in }) -> some View {
        modifier(DeletionAlertModifier(target: target, onDeleted: onDeleted))
    }
}

// MARK: - Semester

struct SemesterFormView: View {
    let semester: Semester?

    @Environment(CourseDataManager.self) private var data
    @Environment(\.dismiss) private var dismiss
    @State private var term: AcademicTerm
    @State private var year: Int
    @State private var name: String
    @State private var color: ColorTag
    /// Once the user types a custom name, stop regenerating it from term and year.
    @State private var nameEdited: Bool

    init(semester: Semester?) {
        self.semester = semester
        let term = semester?.term ?? .current()
        let year = semester?.year ?? Calendar.current.component(.year, from: .now)
        _term = State(initialValue: term)
        _year = State(initialValue: year)
        _name = State(initialValue: semester?.name ?? Semester.defaultName(term: term, year: year))
        _color = State(initialValue: semester?.color ?? .orange)
        _nameEdited = State(initialValue: semester.map { $0.name != Semester.defaultName(term: $0.term, year: $0.year) } ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Term") {
                    Picker("Term", selection: $term) {
                        ForEach(AcademicTerm.allCases) { term in
                            Label(term.displayName, systemImage: term.symbolName).tag(term)
                        }
                    }
                    Stepper(value: $year, in: 2000...2100) {
                        LabeledContent("Year", value: String(year))
                    }
                }
                Section("Name") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, newValue in
                            nameEdited = newValue != Semester.defaultName(term: term, year: year)
                        }
                }
                Section("Color") {
                    ColorTagPicker(selection: $color)
                }
            }
            .onChange(of: term) { regenerateName() }
            .onChange(of: year) { regenerateName() }
            .navigationTitle(semester == nil ? "New Semester" : "Edit Semester")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(semester == nil ? "Create" : "Save") { save() }
                }
            }
        }
    }

    private func regenerateName() {
        if !nameEdited { name = Semester.defaultName(term: term, year: year) }
    }

    private func save() {
        let finalName = name.trimmed.isEmpty ? Semester.defaultName(term: term, year: year) : name.trimmed
        if var existing = semester {
            existing.name = finalName
            existing.term = term
            existing.year = year
            existing.color = color
            data.updateSemester(existing)
        } else {
            data.addSemester(name: finalName, term: term, year: year, color: color)
        }
        dismiss()
    }
}

// MARK: - Course

struct CourseFormView: View {
    let course: Course?

    @Environment(CourseDataManager.self) private var data
    @Environment(\.dismiss) private var dismiss
    @State private var semesterID: UUID?
    @State private var code: String
    @State private var title: String
    @State private var instructor: String
    @State private var color: ColorTag
    @State private var symbolName: String
    @State private var moduleKinds = Set(ModuleKind.defaultSet)

    init(course: Course?, semesterID: UUID?) {
        self.course = course
        _semesterID = State(initialValue: course?.semesterID ?? semesterID)
        _code = State(initialValue: course?.code ?? "")
        _title = State(initialValue: course?.title ?? "")
        _instructor = State(initialValue: course?.instructor ?? "")
        _color = State(initialValue: course?.color ?? ColorTag.allCases.randomElement() ?? .blue)
        _symbolName = State(initialValue: course?.symbolName ?? "book.closed")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Course Code (e.g. EEL 3701C)", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Title (e.g. Digital Logic)", text: $title)
                    TextField("Instructor (optional)", text: $instructor)
                        .textContentType(.name)
                }

                Section("Semester") {
                    Picker("Semester", selection: $semesterID) {
                        ForEach(data.sortedSemesters) { semester in
                            Text(semester.name).tag(Optional(semester.id))
                        }
                    }
                }

                Section("Color") {
                    ColorTagPicker(selection: $color)
                }

                Section("Icon") {
                    SymbolPicker(selection: $symbolName, tint: color.color)
                }

                if course == nil {
                    Section {
                        ForEach(ModuleKind.defaultSet) { kind in
                            Toggle(isOn: moduleBinding(kind)) {
                                Label(kind.defaultName, systemImage: kind.symbolName)
                            }
                        }
                    } header: {
                        Text("Modules")
                    } footer: {
                        Text("Modules organize a course's notes. You can add, rename or remove them later.")
                    }
                }
            }
            .navigationTitle(course == nil ? "New Course" : "Edit Course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(course == nil ? "Create" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if semesterID.flatMap({ data.semester(id: $0) }) == nil {
                    semesterID = data.sortedSemesters.first?.id
                }
            }
        }
    }

    private var canSave: Bool {
        semesterID != nil && !(code.trimmed.isEmpty && title.trimmed.isEmpty)
    }

    private func moduleBinding(_ kind: ModuleKind) -> Binding<Bool> {
        Binding(
            get: { moduleKinds.contains(kind) },
            set: { isOn in
                if isOn { moduleKinds.insert(kind) } else { moduleKinds.remove(kind) }
            }
        )
    }

    private func save() {
        guard let semesterID else { return }
        if var existing = course {
            existing.semesterID = semesterID
            existing.code = code.trimmed
            existing.title = title.trimmed
            existing.instructor = instructor.trimmed
            existing.color = color
            existing.symbolName = symbolName
            data.updateCourse(existing)
        } else {
            data.addCourse(semesterID: semesterID, code: code, title: title, instructor: instructor,
                           color: color, symbolName: symbolName,
                           moduleKinds: ModuleKind.defaultSet.filter(moduleKinds.contains))
        }
        dismiss()
    }
}

// MARK: - Module

struct ModuleFormView: View {
    let module: CourseModule?
    let courseID: UUID

    @Environment(CourseDataManager.self) private var data
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: ModuleKind

    init(module: CourseModule?, courseID: UUID) {
        self.module = module
        self.courseID = courseID
        _name = State(initialValue: module?.name ?? "")
        _kind = State(initialValue: module?.kind ?? .custom)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(kind.defaultName, text: $name)
                }
                Section("Type") {
                    Picker("Type", selection: $kind) {
                        ForEach(ModuleKind.allCases) { kind in
                            Label(kind.defaultName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle(module == nil ? "New Module" : "Edit Module")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(module == nil ? "Create" : "Save") { save() }
                }
            }
        }
    }

    private func save() {
        if var existing = module {
            existing.name = name.trimmed.isEmpty ? kind.defaultName : name.trimmed
            existing.kind = kind
            data.updateModule(existing)
        } else {
            data.addModule(courseID: courseID, name: name, kind: kind)
        }
        dismiss()
    }
}

// MARK: - Pickers

struct ColorTagPicker: View {
    @Binding var selection: ColorTag

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 7), spacing: 14) {
            ForEach(ColorTag.allCases) { tag in
                Button {
                    selection = tag
                } label: {
                    Circle()
                        .fill(tag.color.gradient)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if tag == selection {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(4)
                        .overlay(Circle().strokeBorder(tag == selection ? tag.color : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tag.displayName)
                .accessibilityAddTraits(tag == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}

struct SymbolPicker: View {
    @Binding var selection: String
    let tint: Color

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8), spacing: 10) {
            ForEach(Course.symbolChoices, id: \.self) { symbol in
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(width: 42, height: 42)
                        .foregroundStyle(symbol == selection ? Color.white : tint)
                        .background(symbol == selection ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(symbol == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}
