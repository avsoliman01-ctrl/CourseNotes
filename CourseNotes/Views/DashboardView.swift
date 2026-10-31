import SwiftUI

enum DashboardLayout: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
}

/// Detail column: course grid for a semester, module chips for a course, and the
/// searchable, filterable note collection (grid or list) for any scope.
struct DashboardView: View {
    let scope: LibraryScope
    @Binding var selection: LibraryScope?
    let openNote: (UUID) -> Void

    @Environment(CourseDataManager.self) private var data
    @AppStorage(AppStorageKey.dashboardLayout) private var layout: DashboardLayout = .grid
    @AppStorage(AppStorageKey.dashboardSortOrder) private var sortOrder: NoteSortOrder = .modifiedNewest
    @State private var searchText = ""
    @State private var searchField: NoteSearchField = .all
    @State private var dateFilter: NoteDateFilter = .anyTime
    @State private var moduleFilter: UUID?
    @State private var sheet: LibrarySheet?
    @State private var deletion: DeletionTarget?

    private var filter: NoteFilter {
        NoteFilter(searchText: searchText, searchField: searchField, createdWithin: dateFilter,
                   sortOrder: sortOrder, moduleID: moduleFilter)
    }

    var body: some View {
        let notes = data.notes(in: scope, filter: filter)

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if case .semester(let semesterID) = scope, searchText.isEmpty {
                    courseGrid(semesterID: semesterID)
                }
                if case .course(let courseID) = scope {
                    moduleChips(courseID: courseID)
                }
                notesSection(notes)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search titles, courses or #tags")
        .searchScopes($searchField) {
            ForEach(NoteSearchField.allCases) { field in
                Text(field.title).tag(field)
            }
        }
        .toolbar { toolbarContent }
        .sheet(item: $sheet) { sheet in
            LibrarySheetView(sheet: sheet, onNoteCreated: openNote)
        }
        .deletionAlert($deletion) { deleted in
            if case .module(let module) = deleted, moduleFilter == module.id {
                moduleFilter = nil
            }
        }
        .onChange(of: scope) {
            moduleFilter = nil
        }
    }

    // MARK: Header

    private var title: String {
        switch scope {
        case .allNotes: "All Notes"
        case .recents: "Recents"
        case .favorites: "Favorites"
        case .tag(let tag): "#\(tag)"
        case .semester(let id): data.semester(id: id)?.name ?? "Semester"
        case .course(let id): data.course(id: id)?.shortName ?? "Course"
        }
    }

    @ViewBuilder
    private var header: some View {
        switch scope {
        case .semester(let id):
            if let semester = data.semester(id: id) {
                let courses = data.courses(in: id)
                let noteTotal = courses.reduce(0) { $0 + data.noteCount(inCourse: $1.id) }
                scopeHeader(symbol: semester.term.symbolName, tint: semester.color.color, title: semester.name,
                            subtitle: "\(pluralize(courses.count, "course")) · \(pluralize(noteTotal, "note"))") {
                    Button {
                        sheet = .editSemester(semester)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .course(let id):
            if let course = data.course(id: id) {
                let details = [course.code.isEmpty ? nil : course.title,
                               course.instructor.isEmpty ? nil : course.instructor,
                               data.semester(id: course.semesterID)?.name]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                scopeHeader(symbol: course.symbolName, tint: course.color.color, title: course.shortName,
                            subtitle: details.joined(separator: " · ")) {
                    Button {
                        sheet = .editCourse(course)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        presentNewNote()
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        default:
            EmptyView()
        }
    }

    private func scopeHeader<Actions: View>(symbol: String, tint: Color, title: String, subtitle: String,
                                            @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                actions()
            }
        }
    }

    // MARK: Courses (semester scope)

    private func courseGrid(semesterID: UUID) -> some View {
        let courses = data.courses(in: semesterID)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Courses", count: courses.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 16)], spacing: 16) {
                ForEach(courses) { course in
                    Button {
                        selection = .course(course.id)
                    } label: {
                        CourseCard(course: course,
                                   noteCount: data.noteCount(inCourse: course.id),
                                   lastModified: data.lastModified(inCourse: course.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            sheet = .editCourse(course)
                        } label: {
                            Label("Edit Course", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deletion = .course(course)
                        } label: {
                            Label("Delete Course", systemImage: "trash")
                        }
                    }
                }
                Button {
                    sheet = .newCourse(semesterID: semesterID)
                } label: {
                    AddCard(title: "Add Course", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Modules (course scope)

    private func moduleChips(courseID: UUID) -> some View {
        let modules = data.modules(in: courseID)
        let tint = data.course(id: courseID)?.color.color ?? .accentColor
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ModuleChip(title: "All", symbol: "tray.full", count: data.noteCount(inCourse: courseID),
                           isSelected: moduleFilter == nil, tint: tint) {
                    moduleFilter = nil
                }
                ForEach(modules) { module in
                    ModuleChip(title: module.name, symbol: module.kind.symbolName,
                               count: data.noteCount(inModule: module.id),
                               isSelected: moduleFilter == module.id, tint: tint) {
                        moduleFilter = module.id
                    }
                    .contextMenu {
                        Button {
                            sheet = .editModule(module)
                        } label: {
                            Label("Rename Module", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deletion = .module(module)
                        } label: {
                            Label("Delete Module", systemImage: "trash")
                        }
                    }
                }
                Button {
                    sheet = .newModule(courseID: courseID)
                } label: {
                    Label("Module", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: Notes

    private var notesSectionTitle: String {
        if case .course = scope, let moduleFilter, let module = data.module(id: moduleFilter) {
            return module.name
        }
        if case .semester = scope { return "Notes in This Semester" }
        return "Notes"
    }

    @ViewBuilder
    private func notesSection(_ notes: [NoteDocument]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(notesSectionTitle, count: notes.count)

            if notes.isEmpty {
                emptyState
            } else if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 20)],
                          alignment: .leading, spacing: 24) {
                    ForEach(notes) { note in
                        Button {
                            openNote(note.id)
                        } label: {
                            NoteGridCard(note: note, course: data.course(for: note))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { noteMenu(note) }
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(notes) { note in
                        Button {
                            openNote(note.id)
                        } label: {
                            NoteListRow(note: note, course: data.course(for: note),
                                        moduleName: data.module(id: note.moduleID)?.name)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { noteMenu(note) }

                        if note.id != notes.last?.id {
                            Divider().padding(.leading, 110)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if dateFilter != .anyTime {
                ContentUnavailableView("No Notes in This Period", systemImage: "calendar",
                                       description: Text("Try a wider “Created” filter."))
            } else {
                ContentUnavailableView {
                    Label(scope == .favorites ? "No Favorites" : "No Notes Yet", systemImage: "note.text")
                } description: {
                    Text(scope == .favorites
                         ? "Star a note from its menu to keep it here."
                         : "Create a note to start writing with Apple Pencil.")
                } actions: {
                    if scope != .favorites, !data.courses.isEmpty {
                        Button("New Note") { presentNewNote() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func noteMenu(_ note: NoteDocument) -> some View {
        Button {
            openNote(note.id)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.square")
        }
        Button {
            data.toggleFavorite(id: note.id)
        } label: {
            Label(note.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: note.isFavorite ? "star.slash" : "star")
        }
        Button {
            sheet = .noteDetails(noteID: note.id)
        } label: {
            Label("Rename, Tag or Move…", systemImage: "info.circle")
        }
        Button {
            data.duplicateNote(id: note.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) {
            deletion = .note(note)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: $sortOrder) {
                    ForEach(NoteSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                Picker("Created", selection: $dateFilter) {
                    ForEach(NoteDateFilter.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
            } label: {
                Label("Sort & Filter", systemImage: dateFilter == .anyTime
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Picker("Layout", selection: $layout) {
                Image(systemName: "square.grid.2x2")
                    .accessibilityLabel("Grid")
                    .tag(DashboardLayout.grid)
                Image(systemName: "list.bullet")
                    .accessibilityLabel("List")
                    .tag(DashboardLayout.list)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                presentNewNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(data.courses.isEmpty)
        }
    }

    // MARK: Helpers

    private func presentNewNote() {
        switch scope {
        case .course(let id):
            sheet = .newNote(courseID: id, moduleID: moduleFilter)
        case .semester(let id):
            sheet = .newNote(courseID: data.courses(in: id).first?.id, moduleID: nil)
        default:
            sheet = .newNote(courseID: nil, moduleID: nil)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
