import SwiftUI

struct NoteRoute: Hashable {
    let noteID: UUID
}

/// Sidebar (semesters → courses) → dashboard (course grid / notes) → note editor.
///
/// The editor is pushed onto a stack inside the detail column; while a note is open the sidebar
/// collapses so the canvas gets the full width, and comes back when the note closes.
struct LibraryRootView: View {
    @Environment(CourseDataManager.self) private var data
    @State private var selection: LibraryScope? = .allNotes
    @State private var path: [NoteRoute] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var visibilityBeforeEditing: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            NavigationStack(path: $path) {
                DashboardView(scope: selection ?? .allNotes, selection: $selection) { noteID in
                    path.append(NoteRoute(noteID: noteID))
                }
                .navigationDestination(for: NoteRoute.self) { route in
                    NoteEditorView(noteID: route.noteID, dataManager: data)
                }
            }
        }
        .onChange(of: selection) {
            path.removeAll()
        }
        .onChange(of: data.semesters) { validateSelection() }
        .onChange(of: data.courses) { validateSelection() }
        .onChange(of: path.isEmpty) { _, isEmpty in
            withAnimation {
                if isEmpty {
                    columnVisibility = visibilityBeforeEditing
                } else {
                    visibilityBeforeEditing = columnVisibility
                    columnVisibility = .detailOnly
                }
            }
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(data.lastErrorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { data.lastErrorMessage != nil },
            set: { if !$0 { data.lastErrorMessage = nil } }
        )
    }

    /// Falls back to All Notes when the selected semester or course is deleted (from any screen).
    private func validateSelection() {
        switch selection {
        case .semester(let id)?:
            if data.semester(id: id) == nil { selection = .allNotes }
        case .course(let id)?:
            if data.course(id: id) == nil { selection = .allNotes }
        default:
            break
        }
    }
}

struct SidebarView: View {
    @Environment(CourseDataManager.self) private var data
    @Binding var selection: LibraryScope?

    @State private var collapsedSemesters: Set<UUID> = []
    @State private var sheet: LibrarySheet?
    @State private var deletion: DeletionTarget?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Notes", systemImage: "square.grid.2x2")
                    .badge(data.notes.count)
                    .tag(LibraryScope.allNotes)
                Label("Recents", systemImage: "clock")
                    .tag(LibraryScope.recents)
                Label("Favorites", systemImage: "star")
                    .tag(LibraryScope.favorites)
            }

            if data.semesters.isEmpty {
                Section("Semesters") {
                    Button {
                        sheet = .newSemester
                    } label: {
                        Label("Add Your First Semester", systemImage: "calendar.badge.plus")
                    }
                }
            }

            ForEach(data.sortedSemesters) { semester in
                Section(isExpanded: expansion(for: semester.id)) {
                    Label("Overview", systemImage: "rectangle.grid.2x2")
                        .tag(LibraryScope.semester(semester.id))

                    ForEach(data.courses(in: semester.id)) { course in
                        CourseSidebarRow(course: course, noteCount: data.noteCount(inCourse: course.id))
                            .tag(LibraryScope.course(course.id))
                            .contextMenu { courseMenu(course) }
                    }

                    Button {
                        sheet = .newCourse(semesterID: semester.id)
                    } label: {
                        Label("Add Course", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    semesterHeader(semester)
                }
            }

            if !data.allTags.isEmpty {
                Section("Tags") {
                    ForEach(data.allTags, id: \.self) { tag in
                        Label("#\(tag)", systemImage: "number")
                            .tag(LibraryScope.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("CourseNotes")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    sheet = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        sheet = .newSemester
                    } label: {
                        Label("New Semester", systemImage: "calendar.badge.plus")
                    }
                    Button {
                        sheet = .newCourse(semesterID: data.sortedSemesters.first?.id)
                    } label: {
                        Label("New Course", systemImage: "book.closed")
                    }
                    .disabled(data.semesters.isEmpty)
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            LibrarySheetView(sheet: sheet)
        }
        .deletionAlert($deletion)
    }

    private func semesterHeader(_ semester: Semester) -> some View {
        HStack(spacing: 8) {
            Image(systemName: semester.term.symbolName)
                .foregroundStyle(semester.color.color)
            Text(semester.name)
            Spacer()
            Menu {
                Button {
                    sheet = .newCourse(semesterID: semester.id)
                } label: {
                    Label("Add Course", systemImage: "plus")
                }
                Button {
                    sheet = .editSemester(semester)
                } label: {
                    Label("Edit Semester", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    deletion = .semester(semester)
                } label: {
                    Label("Delete Semester", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.medium)
            }
            .accessibilityLabel("\(semester.name) options")
        }
    }

    @ViewBuilder
    private func courseMenu(_ course: Course) -> some View {
        Button {
            sheet = .editCourse(course)
        } label: {
            Label("Edit Course", systemImage: "pencil")
        }
        Button {
            sheet = .newModule(courseID: course.id)
        } label: {
            Label("Add Module", systemImage: "folder.badge.plus")
        }
        Divider()
        Button(role: .destructive) {
            deletion = .course(course)
        } label: {
            Label("Delete Course", systemImage: "trash")
        }
    }

    private func expansion(for semesterID: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedSemesters.contains(semesterID) },
            set: { isExpanded in
                if isExpanded {
                    collapsedSemesters.remove(semesterID)
                } else {
                    collapsedSemesters.insert(semesterID)
                }
            }
        )
    }
}

struct CourseSidebarRow: View {
    let course: Course
    let noteCount: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(course.shortName)
                    .fontWeight(.medium)
                if !course.code.isEmpty, !course.title.isEmpty {
                    Text(course.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: course.symbolName)
                .foregroundStyle(course.color.color)
        }
        .badge(noteCount)
    }
}
