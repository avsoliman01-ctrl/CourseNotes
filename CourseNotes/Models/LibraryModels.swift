import Foundation
import SwiftUI

// MARK: - Color coding

/// Curated palette used to color-code semesters and courses.
enum ColorTag: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, graphite

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .graphite: .gray
        }
    }

    var displayName: String { rawValue.capitalized }
}

// MARK: - Level 1: Semesters

enum AcademicTerm: String, Codable, CaseIterable, Identifiable {
    case winter, spring, summer, fall

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    /// Chronological position inside a calendar year, used for sorting.
    var order: Int {
        switch self {
        case .winter: 0
        case .spring: 1
        case .summer: 2
        case .fall: 3
        }
    }

    var symbolName: String {
        switch self {
        case .winter: "snowflake"
        case .spring: "leaf"
        case .summer: "sun.max"
        case .fall: "wind"
        }
    }

    /// Best guess for the term a student is currently in.
    static func current(for date: Date = .now) -> AcademicTerm {
        switch Calendar.current.component(.month, from: date) {
        case 1...4: .spring
        case 5...7: .summer
        default: .fall
        }
    }
}

struct Semester: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var term: AcademicTerm
    var year: Int
    var color: ColorTag
    var createdAt = Date()

    /// Larger keys are more recent; the sidebar lists newest semesters first.
    var sortKey: Int { year * 10 + term.order }

    static func defaultName(term: AcademicTerm, year: Int) -> String {
        "\(term.displayName) \(year)"
    }
}

// MARK: - Level 2: Courses

struct Course: Identifiable, Codable, Hashable {
    var id = UUID()
    var semesterID: UUID
    /// Catalog code, e.g. "EEL 3701C".
    var code: String
    /// Descriptive title, e.g. "Digital Logic".
    var title: String
    var instructor: String = ""
    var color: ColorTag
    var symbolName: String = "book.closed"
    var createdAt = Date()

    var displayName: String {
        if code.isEmpty { return title.isEmpty ? "Untitled Course" : title }
        return title.isEmpty ? code : "\(code) – \(title)"
    }

    /// Compact label for chips and badges.
    var shortName: String { code.isEmpty ? displayName : code }

    static let symbolChoices = [
        "book.closed", "function", "sum", "cpu", "memorychip", "bolt",
        "atom", "flask", "testtube.2", "leaf", "globe.americas", "building.columns",
        "chart.xyaxis.line", "laptopcomputer", "terminal", "gearshape.2", "brain.head.profile", "stethoscope",
        "paintbrush", "music.note", "text.book.closed", "character.book.closed", "scalemass", "hammer"
    ]
}

// MARK: - Level 3: Modules

enum ModuleKind: String, Codable, CaseIterable, Identifiable {
    case lectures, labs, homework, examPrep, custom

    var id: String { rawValue }

    var defaultName: String {
        switch self {
        case .lectures: "Lectures"
        case .labs: "Labs"
        case .homework: "Homework"
        case .examPrep: "Exam Prep"
        case .custom: "Notes"
        }
    }

    /// Used to auto-title new notes ("Lecture · Oct 31").
    var singularName: String {
        switch self {
        case .lectures: "Lecture"
        case .labs: "Lab"
        case .homework: "Homework"
        case .examPrep: "Review"
        case .custom: "Note"
        }
    }

    var symbolName: String {
        switch self {
        case .lectures: "studentdesk"
        case .labs: "flask"
        case .homework: "doc.text"
        case .examPrep: "graduationcap"
        case .custom: "folder"
        }
    }

    static let defaultSet: [ModuleKind] = [.lectures, .labs, .homework, .examPrep]
}

struct CourseModule: Identifiable, Codable, Hashable {
    var id = UUID()
    var courseID: UUID
    var name: String
    var kind: ModuleKind
    var sortIndex: Int
    var createdAt = Date()
}

// MARK: - Level 4: Notes

/// Metadata for one canvas document. The ink itself lives in a separate
/// `<id>.drawing` file (binary `PKDrawing` data) managed by `CourseDataManager`.
struct NoteDocument: Identifiable, Codable, Hashable {
    var id = UUID()
    var moduleID: UUID
    var title: String
    var template: PaperTemplate
    var tags: [String] = []
    var isFavorite = false
    var createdAt = Date()
    var modifiedAt = Date()

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }
}

/// Everything except drawing data, persisted as `library.json`.
struct LibrarySnapshot: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion = LibrarySnapshot.currentSchemaVersion
    var semesters: [Semester] = []
    var courses: [Course] = []
    var modules: [CourseModule] = []
    var notes: [NoteDocument] = []
}

// MARK: - Navigation scope

/// What the sidebar has selected; drives the dashboard's content and note queries.
enum LibraryScope: Hashable {
    case allNotes
    case recents
    case favorites
    case semester(UUID)
    case course(UUID)
    case tag(String)
}

// MARK: - Tags

enum TagFormatter {
    /// "#Exam 2 " -> "exam-2"
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
    }

    /// Splits user input on commas, returning unique normalized tags in input order.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
