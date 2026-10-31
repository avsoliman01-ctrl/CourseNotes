import Foundation
import Observation
import PencilKit
import UIKit

// MARK: - Query options

enum NoteSearchField: String, CaseIterable, Identifiable {
    case all, title, course, tag

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .title: "Title"
        case .course: "Course"
        case .tag: "Tag"
        }
    }
}

/// Filters on a note's creation date.
enum NoteDateFilter: String, CaseIterable, Identifiable {
    case anyTime, today, pastWeek, pastMonth, pastYear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .anyTime: "Any Time"
        case .today: "Today"
        case .pastWeek: "Past 7 Days"
        case .pastMonth: "Past 30 Days"
        case .pastYear: "Past Year"
        }
    }

    func includes(_ date: Date, now: Date = .now) -> Bool {
        let calendar = Calendar.current
        let days: Int
        switch self {
        case .anyTime: return true
        case .today: return calendar.isDateInToday(date)
        case .pastWeek: days = 7
        case .pastMonth: days = 30
        case .pastYear: days = 365
        }
        guard let start = calendar.date(byAdding: .day, value: -days, to: now) else { return true }
        return date >= start
    }
}

enum NoteSortOrder: String, CaseIterable, Identifiable {
    case modifiedNewest, createdNewest, createdOldest, title

    var id: String { rawValue }
    var title: String {
        switch self {
        case .modifiedNewest: "Last Modified"
        case .createdNewest: "Newest First"
        case .createdOldest: "Oldest First"
        case .title: "Title"
        }
    }
}

struct NoteFilter: Equatable {
    var searchText = ""
    var searchField: NoteSearchField = .all
    var createdWithin: NoteDateFilter = .anyTime
    var sortOrder: NoteSortOrder = .modifiedNewest
    /// Restricts results to one module (used by the course page's module chips).
    var moduleID: UUID?
}

// MARK: - File layout

/// Where everything lives on disk:
///
///     Documents/CourseNotes Library/library.json      metadata (semesters, courses, modules, notes)
///     Documents/CourseNotes Library/Drawings/<id>.drawing   PKDrawing.dataRepresentation()
///     Library/Caches/Thumbnails/<id>.png               regenerable previews
///
/// `Documents` is exposed in the Files app (UIFileSharingEnabled), so the library can be backed up
/// by hand — important for side-loaded builds that may be deleted when a signature expires.
struct LibraryStorage {
    let rootURL: URL
    let thumbnailsURL: URL

    init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        rootURL = documents.appending(path: "CourseNotes Library", directoryHint: .isDirectory)
        thumbnailsURL = caches.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    var libraryURL: URL { rootURL.appending(path: "library.json") }
    var drawingsURL: URL { rootURL.appending(path: "Drawings", directoryHint: .isDirectory) }

    func drawingURL(for id: UUID) -> URL { drawingsURL.appending(path: "\(id.uuidString).drawing") }
    func thumbnailURL(for id: UUID) -> URL { thumbnailsURL.appending(path: "\(id.uuidString).png") }

    func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: drawingsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
    }
}

// MARK: - Data manager

/// Single source of truth for the academic hierarchy and note persistence.
///
/// Metadata is held in memory and written to `library.json` with a short debounce. Ink is read and
/// written on a serial I/O queue, so a note reopened right after closing always sees its latest save.
@MainActor
@Observable
final class CourseDataManager {
    private(set) var semesters: [Semester] = []
    private(set) var courses: [Course] = []
    private(set) var modules: [CourseModule] = []
    private(set) var notes: [NoteDocument] = []

    /// Description of the most recent persistence failure; the root view presents it as an alert.
    var lastErrorMessage: String?

    let storage: LibraryStorage
    private let ioQueue = DispatchQueue(label: "CourseNotes.io", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "CourseNotes.thumbnails", qos: .utility, attributes: .concurrent)
    private let thumbnailCache = NSCache<NSUUID, UIImage>()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(storage: LibraryStorage = LibraryStorage()) {
        self.storage = storage
        thumbnailCache.countLimit = 400
        load()
    }

    // MARK: Lookups

    var sortedSemesters: [Semester] {
        semesters.sorted { ($0.sortKey, $0.createdAt) > ($1.sortKey, $1.createdAt) }
    }

    var allTags: [String] {
        Set(notes.flatMap(\.tags)).sorted()
    }

    func semester(id: UUID) -> Semester? { semesters.first { $0.id == id } }
    func course(id: UUID) -> Course? { courses.first { $0.id == id } }
    func module(id: UUID) -> CourseModule? { modules.first { $0.id == id } }
    func note(id: UUID) -> NoteDocument? { notes.first { $0.id == id } }

    func courses(in semesterID: UUID) -> [Course] {
        courses.filter { $0.semesterID == semesterID }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func modules(in courseID: UUID) -> [CourseModule] {
        modules.filter { $0.courseID == courseID }.sorted { $0.sortIndex < $1.sortIndex }
    }

    func course(for note: NoteDocument) -> Course? {
        module(id: note.moduleID).flatMap { course(id: $0.courseID) }
    }

    func noteCount(inCourse courseID: UUID) -> Int {
        let moduleIDs = Set(modules.lazy.filter { $0.courseID == courseID }.map(\.id))
        return notes.lazy.filter { moduleIDs.contains($0.moduleID) }.count
    }

    func noteCount(inModule moduleID: UUID) -> Int {
        notes.lazy.filter { $0.moduleID == moduleID }.count
    }

    func lastModified(inCourse courseID: UUID) -> Date? {
        let moduleIDs = Set(modules.lazy.filter { $0.courseID == courseID }.map(\.id))
        return notes.lazy.filter { moduleIDs.contains($0.moduleID) }.map(\.modifiedAt).max()
    }

    /// "Lecture · Oct 31" style default title for a new note in `moduleID`.
    func suggestedTitle(for moduleID: UUID) -> String {
        let kind = module(id: moduleID)?.kind ?? .custom
        return "\(kind.singularName) · \(Date.now.formatted(.dateTime.month(.abbreviated).day()))"
    }

    // MARK: Search & filter

    func notes(in scope: LibraryScope, filter: NoteFilter) -> [NoteDocument] {
        let courseIDByModule = Dictionary(modules.map { ($0.id, $0.courseID) }, uniquingKeysWith: { first, _ in first })
        let courseByID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func courseOf(_ note: NoteDocument) -> Course? {
            courseIDByModule[note.moduleID].flatMap { courseByID[$0] }
        }

        var result = notes.filter { note in
            switch scope {
            case .allNotes, .recents: true
            case .favorites: note.isFavorite
            case .tag(let tag): note.tags.contains(tag)
            case .course(let id): courseIDByModule[note.moduleID] == id
            case .semester(let id): courseOf(note)?.semesterID == id
            }
        }

        if let moduleID = filter.moduleID {
            result.removeAll { $0.moduleID != moduleID }
        }
        if filter.createdWithin != .anyTime {
            result.removeAll { !filter.createdWithin.includes($0.createdAt) }
        }

        let query = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result.removeAll { !Self.note($0, matches: query, in: filter.searchField, course: courseOf($0)) }
        }

        if scope == .recents {
            result.sort { $0.modifiedAt > $1.modifiedAt }
            return Array(result.prefix(40))
        }
        switch filter.sortOrder {
        case .modifiedNewest: result.sort { $0.modifiedAt > $1.modifiedAt }
        case .createdNewest: result.sort { $0.createdAt > $1.createdAt }
        case .createdOldest: result.sort { $0.createdAt < $1.createdAt }
        case .title: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return result
    }

    /// Typing "#midterm" in the "All" scope searches tags only.
    private static func note(_ note: NoteDocument, matches query: String, in field: NoteSearchField, course: Course?) -> Bool {
        let titleMatches = { note.title.localizedStandardContains(query) }
        let courseMatches = {
            guard let course else { return false }
            return course.code.localizedStandardContains(query)
                || course.title.localizedStandardContains(query)
                || course.instructor.localizedStandardContains(query)
        }
        let tagMatches = {
            let tag = TagFormatter.normalize(query)
            return !tag.isEmpty && note.tags.contains { $0.contains(tag) }
        }

        switch field {
        case .all: return query.hasPrefix("#") ? tagMatches() : titleMatches() || courseMatches() || tagMatches()
        case .title: return titleMatches()
        case .course: return courseMatches()
        case .tag: return tagMatches()
        }
    }

    // MARK: Semesters

    @discardableResult
    func addSemester(name: String, term: AcademicTerm, year: Int, color: ColorTag) -> Semester {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let semester = Semester(
            name: trimmed.isEmpty ? Semester.defaultName(term: term, year: year) : trimmed,
            term: term, year: year, color: color
        )
        semesters.append(semester)
        scheduleSave()
        return semester
    }

    func updateSemester(_ semester: Semester) {
        guard let index = semesters.firstIndex(where: { $0.id == semester.id }) else { return }
        semesters[index] = semester
        scheduleSave()
    }

    /// Deletes the semester and everything inside it, including ink files.
    func deleteSemester(id: UUID) {
        for course in courses where course.semesterID == id {
            removeContents(ofCourse: course.id)
        }
        courses.removeAll { $0.semesterID == id }
        semesters.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Courses

    @discardableResult
    func addCourse(semesterID: UUID, code: String, title: String, instructor: String,
                   color: ColorTag, symbolName: String, moduleKinds: [ModuleKind]) -> Course {
        let course = Course(
            semesterID: semesterID,
            code: code.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            instructor: instructor.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color,
            symbolName: symbolName
        )
        courses.append(course)
        let kinds = moduleKinds.isEmpty ? [ModuleKind.custom] : moduleKinds
        for (index, kind) in kinds.enumerated() {
            modules.append(CourseModule(courseID: course.id, name: kind.defaultName, kind: kind, sortIndex: index))
        }
        scheduleSave()
        return course
    }

    func updateCourse(_ course: Course) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[index] = course
        scheduleSave()
    }

    func deleteCourse(id: UUID) {
        removeContents(ofCourse: id)
        courses.removeAll { $0.id == id }
        scheduleSave()
    }

    private func removeContents(ofCourse courseID: UUID) {
        let moduleIDs = Set(modules.filter { $0.courseID == courseID }.map(\.id))
        deleteFiles(for: notes.filter { moduleIDs.contains($0.moduleID) }.map(\.id))
        notes.removeAll { moduleIDs.contains($0.moduleID) }
        modules.removeAll { $0.courseID == courseID }
    }

    // MARK: Modules

    @discardableResult
    func addModule(courseID: UUID, name: String, kind: ModuleKind) -> CourseModule {
        let nextIndex = (modules(in: courseID).map(\.sortIndex).max() ?? -1) + 1
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let module = CourseModule(courseID: courseID, name: trimmed.isEmpty ? kind.defaultName : trimmed,
                                  kind: kind, sortIndex: nextIndex)
        modules.append(module)
        scheduleSave()
        return module
    }

    func updateModule(_ module: CourseModule) {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        modules[index] = module
        scheduleSave()
    }

    func deleteModule(id: UUID) {
        deleteFiles(for: notes.filter { $0.moduleID == id }.map(\.id))
        notes.removeAll { $0.moduleID == id }
        modules.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Notes

    @discardableResult
    func createNote(in moduleID: UUID, title: String, template: PaperTemplate, tags: [String] = []) -> NoteDocument {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = NoteDocument(moduleID: moduleID,
                                title: trimmed.isEmpty ? suggestedTitle(for: moduleID) : trimmed,
                                template: template, tags: tags)
        notes.append(note)
        scheduleSave()
        return note
    }

    func renameNote(id: UUID, to title: String) {
        mutateNote(id) { $0.title = title }
    }

    func setTags(_ tags: [String], for id: UUID) {
        mutateNote(id) { $0.tags = tags }
    }

    func setTemplate(_ template: PaperTemplate, for id: UUID) {
        invalidateThumbnail(for: id)
        mutateNote(id) { $0.template = template }
    }

    func toggleFavorite(id: UUID) {
        mutateNote(id, touchesModificationDate: false) { $0.isFavorite.toggle() }
    }

    func moveNote(id: UUID, toModule moduleID: UUID) {
        mutateNote(id, touchesModificationDate: false) { $0.moduleID = moduleID }
    }

    @discardableResult
    func duplicateNote(id: UUID) -> NoteDocument? {
        guard let original = note(id: id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.title = "\(original.title) Copy"
        copy.isFavorite = false
        copy.createdAt = .now
        copy.modifiedAt = .now
        notes.append(copy)

        let source = storage.drawingURL(for: original.id)
        let destination = storage.drawingURL(for: copy.id)
        ioQueue.async {
            try? FileManager.default.copyItem(at: source, to: destination)
        }
        scheduleSave()
        return copy
    }

    func deleteNote(id: UUID) {
        deleteFiles(for: [id])
        notes.removeAll { $0.id == id }
        scheduleSave()
    }

    private func mutateNote(_ id: UUID, touchesModificationDate: Bool = true, _ change: (inout NoteDocument) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
        if touchesModificationDate { notes[index].modifiedAt = .now }
        scheduleSave()
    }

    // MARK: Ink (PKDrawing) persistence

    /// Loads a note's ink. Runs on the I/O queue so it is ordered after any pending save.
    func loadDrawing(for noteID: UUID) async -> PKDrawing {
        let url = storage.drawingURL(for: noteID)
        let result: Result<PKDrawing, Error> = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: Self.readDrawing(at: url))
            }
        }
        switch result {
        case .success(let drawing):
            return drawing
        case .failure(let error):
            report(error, while: "open this note's ink (the damaged file was kept next to it)")
            return PKDrawing()
        }
    }

    /// Writes ink as binary `PKDrawing` data, then refreshes the thumbnail and modification date.
    func saveDrawing(_ drawing: PKDrawing, for noteID: UUID) {
        guard let note = self.note(id: noteID) else { return }
        let data = drawing.dataRepresentation()
        let template = note.template
        let drawingURL = storage.drawingURL(for: noteID)
        let thumbnailURL = storage.thumbnailURL(for: noteID)

        ioQueue.async { [weak self] in
            var writeError: Error?
            do {
                try data.write(to: drawingURL, options: .atomic)
            } catch {
                writeError = error
            }
            let thumbnail = NoteRenderer.thumbnail(for: drawing, template: template)
            try? thumbnail.pngData()?.write(to: thumbnailURL, options: .atomic)

            Task { @MainActor in
                guard let self else { return }
                if let writeError {
                    self.report(writeError, while: "save “\(note.title)”")
                    return
                }
                self.thumbnailCache.setObject(thumbnail, forKey: noteID as NSUUID)
                self.mutateNote(noteID) { _ in }
            }
        }
    }

    /// Cached thumbnail, rendered in the background on first request.
    func thumbnail(for note: NoteDocument) async -> UIImage {
        if let cached = thumbnailCache.object(forKey: note.id as NSUUID) { return cached }
        let drawingURL = storage.drawingURL(for: note.id)
        let thumbnailURL = storage.thumbnailURL(for: note.id)
        let template = note.template

        let image: UIImage = await withCheckedContinuation { continuation in
            thumbnailQueue.async {
                if let data = try? Data(contentsOf: thumbnailURL), let cached = UIImage(data: data) {
                    continuation.resume(returning: cached)
                    return
                }
                let drawing = (try? Self.readDrawing(at: drawingURL).get()) ?? PKDrawing()
                let rendered = NoteRenderer.thumbnail(for: drawing, template: template)
                try? rendered.pngData()?.write(to: thumbnailURL, options: .atomic)
                continuation.resume(returning: rendered)
            }
        }
        thumbnailCache.setObject(image, forKey: note.id as NSUUID)
        return image
    }

    nonisolated private static func readDrawing(at url: URL) -> Result<PKDrawing, Error> {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .success(PKDrawing())
        }
        do {
            return .success(try PKDrawing(data: Data(contentsOf: url)))
        } catch {
            // Never let an autosave overwrite a file we failed to parse.
            let quarantine = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return .failure(error)
        }
    }

    private func invalidateThumbnail(for id: UUID) {
        thumbnailCache.removeObject(forKey: id as NSUUID)
        try? FileManager.default.removeItem(at: storage.thumbnailURL(for: id))
    }

    private func deleteFiles(for noteIDs: [UUID]) {
        guard !noteIDs.isEmpty else { return }
        noteIDs.forEach { thumbnailCache.removeObject(forKey: $0 as NSUUID) }
        let urls = noteIDs.flatMap { [storage.drawingURL(for: $0), storage.thumbnailURL(for: $0)] }
        ioQueue.async {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    // MARK: Library file

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Encodes metadata immediately and writes it on the I/O queue.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = LibrarySnapshot(semesters: semesters, courses: courses, modules: modules, notes: notes)
        let url = storage.libraryURL
        do {
            let data = try Self.makeEncoder().encode(snapshot)
            ioQueue.async { [weak self] in
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    Task { @MainActor in self?.report(error, while: "save your library") }
                }
            }
        } catch {
            report(error, while: "save your library")
        }
    }

    /// Called when the app leaves the foreground: commits metadata and waits for in-flight writes.
    func flushToDisk() {
        saveNow()
        ioQueue.sync {}
    }

    /// Zips the whole library folder (metadata + ink) into a temporary file for sharing.
    func makeBackupArchive() throws -> URL {
        flushToDisk()
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let destination = FileManager.default.temporaryDirectory.appending(path: "CourseNotes Backup \(stamp).zip")
        var coordinationError: NSError?
        var copyError: Error?
        // `.forUploading` makes the system produce a zip of the directory for us.
        NSFileCoordinator().coordinate(readingItemAt: storage.rootURL, options: .forUploading, error: &coordinationError) { zipURL in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }

    private func load() {
        do {
            try storage.prepareDirectories()
        } catch {
            report(error, while: "create the library folder")
        }

        let url = storage.libraryURL
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            do {
                let snapshot = try Self.makeDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: url))
                semesters = snapshot.semesters
                courses = snapshot.courses
                modules = snapshot.modules
                notes = snapshot.notes
            } catch {
                // Set the unreadable file aside instead of overwriting it; ink is recovered below.
                let stamp = Int(Date.now.timeIntervalSince1970)
                let backup = storage.rootURL.appending(path: "library-unreadable-\(stamp).json")
                try? FileManager.default.moveItem(at: url, to: backup)
                report(error, while: "read your library (it was kept as \(backup.lastPathComponent))")
            }
        } else {
            seedStarterLibrary()
        }
        recoverOrphanedDrawings()
    }

    /// First launch: one semester with two example courses so the app isn't empty.
    private func seedStarterLibrary() {
        let year = Calendar.current.component(.year, from: .now)
        let term = AcademicTerm.current()
        let semester = addSemester(name: Semester.defaultName(term: term, year: year), term: term, year: year, color: .orange)
        addCourse(semesterID: semester.id, code: "EEL 3701C", title: "Digital Logic", instructor: "",
                  color: .blue, symbolName: "cpu", moduleKinds: ModuleKind.defaultSet)
        addCourse(semesterID: semester.id, code: "MAC 2313", title: "Calculus III", instructor: "",
                  color: .purple, symbolName: "function", moduleKinds: ModuleKind.defaultSet)
        saveNow()
    }

    /// Ink files without metadata (e.g. after restoring a backup or losing library.json)
    /// are re-attached to a "Recovered Notes" course instead of silently disappearing.
    private func recoverOrphanedDrawings() {
        let known = Set(notes.map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: storage.drawingsURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let orphans: [(UUID, Date)] = files.compactMap { url in
            guard url.pathExtension == "drawing",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !known.contains(id) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            return (id, date)
        }
        guard !orphans.isEmpty else { return }

        let moduleID = recoveryModuleID()
        for (index, orphan) in orphans.sorted(by: { $0.1 < $1.1 }).enumerated() {
            notes.append(NoteDocument(id: orphan.0, moduleID: moduleID, title: "Recovered Note \(index + 1)",
                                      template: .blank, createdAt: orphan.1, modifiedAt: orphan.1))
        }
        saveNow()
    }

    private func recoveryModuleID() -> UUID {
        if let course = courses.first(where: { $0.code == "RECOVERED" }), let module = modules(in: course.id).first {
            return module.id
        }
        let year = Calendar.current.component(.year, from: .now)
        let term = AcademicTerm.current()
        let semester = sortedSemesters.first
            ?? addSemester(name: Semester.defaultName(term: term, year: year), term: term, year: year, color: .graphite)
        let course = addCourse(semesterID: semester.id, code: "RECOVERED", title: "Recovered Notes", instructor: "",
                               color: .graphite, symbolName: "lifepreserver", moduleKinds: [.custom])
        return modules(in: course.id)[0].id
    }

    private func report(_ error: Error, while action: String) {
        lastErrorMessage = "Couldn't \(action). \(error.localizedDescription)"
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
