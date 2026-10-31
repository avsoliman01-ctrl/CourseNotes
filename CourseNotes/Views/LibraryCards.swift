import SwiftUI

struct CourseCard: View {
    let course: Course
    let noteCount: Int
    let lastModified: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: course.symbolName)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(course.color.color.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Spacer()
                Text("\(noteCount)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(course.shortName)
                    .font(.headline)
                    .lineLimit(1)
                if !course.code.isEmpty, !course.title.isEmpty {
                    Text(course.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !course.instructor.isEmpty {
                Label(course.instructor, systemImage: "person")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(lastModified.map { "Edited \($0.formatted(.relative(presentation: .named)))" } ?? "No notes yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, style: .continuous)
                .fill(course.color.color)
                .frame(width: 5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct AddCard: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 150)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ModuleChip: View {
    let title: String
    let symbol: String
    let count: Int
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CourseChip: View {
    let course: Course

    var body: some View {
        Text(course.shortName)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(course.color.color)
            .background(course.color.color.opacity(0.16), in: Capsule())
    }
}

/// Paper-and-ink preview, loaded asynchronously and refreshed whenever the note is modified.
struct NoteThumbnailView: View {
    let note: NoteDocument

    @Environment(CourseDataManager.self) private var data
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.white)
            .aspectRatio(CanvasMetrics.thumbnailAspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: note.modifiedAt) {
                let rendered = await data.thumbnail(for: note)
                withAnimation(.easeOut(duration: 0.15)) { image = rendered }
            }
            .accessibilityHidden(true)
    }
}

struct NoteGridCard: View {
    let note: NoteDocument
    let course: Course?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoteThumbnailView(note: note)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
                .overlay(alignment: .topTrailing) {
                    if note.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(0.06), radius: 6, y: 3)

            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 6) {
                if let course {
                    CourseChip(course: course)
                }
                Text(note.modifiedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !note.tags.isEmpty {
                Text(note.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct NoteListRow: View {
    let note: NoteDocument
    let course: Course?
    let moduleName: String?

    var body: some View {
        HStack(spacing: 14) {
            NoteThumbnailView(note: note)
                .frame(width: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(note.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if note.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 6) {
                    if let course {
                        CourseChip(course: course)
                    }
                    if let moduleName {
                        Text(moduleName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !note.tags.isEmpty {
                    Text(note.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(note.modifiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Created \(note.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
