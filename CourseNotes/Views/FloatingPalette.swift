import SwiftUI

enum PaletteStorageKey {
    /// Palette center as a fraction of the editor area (0...1), so it survives rotation and Split View.
    static let anchorX = "palette.anchorX"
    static let anchorY = "palette.anchorY"
    static let dock = "palette.dock"
    static let isPinned = "palette.isPinned"
    static let isHidden = "palette.isHidden"
}

/// Side edge the palette is docked against (vertical layout), if any.
enum PaletteDock: String {
    case floating, leading, trailing
}

enum PaletteLayout {
    /// Puts the palette back at the top center, horizontal and visible. The pin setting is kept.
    /// Every view reading these keys through `@AppStorage` updates immediately.
    static func reset(_ defaults: UserDefaults = .standard) {
        defaults.set(0.5, forKey: PaletteStorageKey.anchorX)
        defaults.set(0.0, forKey: PaletteStorageKey.anchorY)
        defaults.set(PaletteDock.floating.rawValue, forKey: PaletteStorageKey.dock)
        defaults.set(false, forKey: PaletteStorageKey.isHidden)
    }
}

/// Hosts the tool palette as a floating control the user can drag anywhere, pin in place,
/// or collapse to a small button. Position and state persist across notes and launches.
///
/// - Dragging is only possible from the grip, so it never competes with the tool buttons,
///   and never while pinned. Double-tapping the grip puts the palette back at the top center.
/// - The position is clamped to the visible area on every layout pass, so the palette cannot be
///   lost after rotating the iPad or resizing the window.
/// - It stays clear of the left and right screen edges, where iPadOS's own edge swipes (back,
///   show sidebar) would otherwise take touches meant for the grip.
/// - Dropped against the left or right edge it docks there in a vertical layout.
struct FloatingPalette: View {
    let controller: CanvasController

    @AppStorage(PaletteStorageKey.anchorX) private var anchorX = 0.5
    @AppStorage(PaletteStorageKey.anchorY) private var anchorY = 0.0
    @AppStorage(PaletteStorageKey.dock) private var dock: PaletteDock = .floating
    @AppStorage(PaletteStorageKey.isPinned) private var isPinned = false
    @AppStorage(PaletteStorageKey.isHidden) private var isHidden = false
    @State private var contentSize: CGSize = .zero
    /// Clamped center when the current drag began; nil when not dragging.
    @State private var dragStart: CGPoint?
    @State private var dragTranslation: CGSize = .zero

    /// Wide enough that the grip never sits in the system's edge-swipe zone.
    private let sideMargin: CGFloat = 32
    private let topMargin: CGFloat = 10
    /// Keeps the palette above the home-indicator gesture area.
    private let bottomMargin: CGFloat = 20
    /// The vertical layout only fits in reasonably tall windows.
    private let minimumHeightForVertical: CGFloat = 560

    private var isDragging: Bool { dragStart != nil }

    var body: some View {
        // Only the palette itself is hit-testable; the rest of this layer passes touches
        // straight through to the canvas.
        GeometryReader { proxy in
            let area = proxy.size
            content(in: area)
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: PaletteSizeKey.self, value: inner.size)
                    }
                )
                .position(center(in: area))
        }
        .onPreferenceChange(PaletteSizeKey.self) { contentSize = $0 }
        .animation(.snappy(duration: 0.25), value: isHidden)
        .animation(isDragging ? nil : .snappy(duration: 0.3), value: anchorX)
        .animation(isDragging ? nil : .snappy(duration: 0.3), value: anchorY)
        .animation(.snappy(duration: 0.25), value: dock)
    }

    // MARK: Content

    @ViewBuilder
    private func content(in area: CGSize) -> some View {
        if isHidden {
            Button {
                isHidden = false
            } label: {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 46, height: 46)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.quaternary))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show tool palette")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            let axis: Axis = prefersVertical(in: area) ? .vertical : .horizontal
            let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
            layout {
                chrome(axis: axis, area: area)
                ToolPaletteView(controller: controller, axis: axis)
            }
            .padding(axis == .vertical ? .vertical : .horizontal, 8)
            .padding(axis == .vertical ? .horizontal : .vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(isDragging ? 0.25 : 0.12), radius: isDragging ? 18 : 12, y: 4)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    /// Grip (drag), pin and hide controls at the leading end of the palette.
    private func chrome(axis: Axis, area: CGSize) -> some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            Image(systemName: "line.3.horizontal")
                .rotationEffect(axis == .vertical ? .zero : .degrees(90))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isPinned ? Color.secondary.opacity(0.35) : Color.secondary)
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
                .gesture(dragGesture(in: area), including: isPinned ? .none : .all)
                .simultaneousGesture(TapGesture(count: 2).onEnded { PaletteLayout.reset() })
                .help("Drag to move. Double-tap to put back at the top.")
                .accessibilityLabel(isPinned ? "Palette pinned" : "Move palette")
                .accessibilityHint("Drag to reposition the tool palette. Double-tap to reset its position.")
                .accessibilityAction(named: "Reset Position") { PaletteLayout.reset() }

            Button {
                isPinned.toggle()
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin palette" : "Pin palette in place")
            .accessibilityLabel(isPinned ? "Unpin palette" : "Pin palette")

            Button {
                isHidden = true
            } label: {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide palette")
            .accessibilityLabel("Hide tool palette")

            Divider()
                .frame(width: axis == .vertical ? 24 : nil, height: axis == .vertical ? nil : 24)
                .padding(axis == .vertical ? .vertical : .horizontal, 4)
        }
    }

    // MARK: Position

    /// Docked against a side edge in a window tall enough for the vertical layout. Decided from
    /// the saved dock only, so the layout doesn't flip back and forth in the middle of a drag.
    private func prefersVertical(in area: CGSize) -> Bool {
        dock != .floating && area.height >= minimumHeightForVertical
    }

    private func center(in area: CGSize) -> CGPoint {
        if let dragStart {
            return clamped(CGPoint(x: dragStart.x + dragTranslation.width,
                                   y: dragStart.y + dragTranslation.height), in: area)
        }
        return clamped(CGPoint(x: anchorX * area.width, y: anchorY * area.height), in: area)
    }

    private func clamped(_ point: CGPoint, in area: CGSize) -> CGPoint {
        let halfWidth = contentSize.width / 2
        let halfHeight = contentSize.height / 2
        let minX = sideMargin + halfWidth
        let maxX = max(minX, area.width - sideMargin - halfWidth)
        let minY = topMargin + halfHeight
        let maxY = max(minY, area.height - bottomMargin - halfHeight)
        return CGPoint(x: min(max(point.x, minX), maxX), y: min(max(point.y, minY), maxY))
    }

    private func dragGesture(in area: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                // Start from where the palette is actually drawn, so there is no dead zone when it
                // is clamped against an edge.
                if dragStart == nil { dragStart = center(in: area) }
                dragTranslation = value.translation
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                let raw = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                let end = clamped(raw, in: area)
                dragStart = nil
                dragTranslation = .zero
                guard area.width > 0, area.height > 0 else { return }

                // Dropping it within a tenth of the width from a side docks it there.
                if raw.x < area.width * 0.1 {
                    dock = .leading
                    anchorX = 0
                } else if raw.x > area.width * 0.9 {
                    dock = .trailing
                    anchorX = 1
                } else {
                    dock = .floating
                    anchorX = Double(end.x / area.width)
                }
                // Stored clamped, so "against the top edge" stays that way at any window size.
                anchorY = Double(end.y / area.height)
            }
    }
}

private struct PaletteSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
