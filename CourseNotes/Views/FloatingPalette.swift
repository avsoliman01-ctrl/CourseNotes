import SwiftUI

enum PaletteStorageKey {
    /// Palette center as a fraction of the editor area (0...1), so it survives rotation and Split View.
    static let anchorX = "palette.anchorX"
    static let anchorY = "palette.anchorY"
    static let isPinned = "palette.isPinned"
    static let isHidden = "palette.isHidden"
}

/// Hosts the tool palette as a floating control the user can drag anywhere, pin in place,
/// or collapse to a small button. Position and state persist across notes and launches.
///
/// - Dragging is only possible from the grip, so it never competes with the tool buttons,
///   and never while pinned.
/// - The position is clamped to the visible area on every layout pass, so the palette cannot be
///   lost after rotating the iPad or resizing the window.
/// - Docked against the left or right edge it switches to a vertical layout.
struct FloatingPalette: View {
    let controller: CanvasController

    @AppStorage(PaletteStorageKey.anchorX) private var anchorX = 0.5
    @AppStorage(PaletteStorageKey.anchorY) private var anchorY = 0.0
    @AppStorage(PaletteStorageKey.isPinned) private var isPinned = false
    @AppStorage(PaletteStorageKey.isHidden) private var isHidden = false
    @State private var contentSize: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false

    private let margin: CGFloat = 8

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
            let axis: Axis = prefersVertical ? .vertical : .horizontal
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
                .accessibilityLabel(isPinned ? "Palette pinned" : "Move palette")
                .accessibilityHint("Drag to reposition the tool palette")

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

    /// Docked against a side edge. Decided from the saved position only, so the layout
    /// doesn't flip back and forth in the middle of a drag.
    private var prefersVertical: Bool {
        anchorX < 0.07 || anchorX > 0.93
    }

    private func center(in area: CGSize) -> CGPoint {
        let base = CGPoint(x: anchorX * area.width + dragTranslation.width,
                           y: anchorY * area.height + dragTranslation.height)
        return clamped(base, in: area)
    }

    private func clamped(_ point: CGPoint, in area: CGSize) -> CGPoint {
        let halfWidth = contentSize.width / 2 + margin
        let halfHeight = contentSize.height / 2 + margin
        return CGPoint(x: min(max(point.x, halfWidth), max(halfWidth, area.width - halfWidth)),
                       y: min(max(point.y, halfHeight), max(halfHeight, area.height - halfHeight)))
    }

    private func dragGesture(in area: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                dragTranslation = value.translation
            }
            .onEnded { value in
                // Store the clamped position, so "against the top edge" stays that way at any size.
                let end = clamped(CGPoint(x: anchorX * area.width + value.translation.width,
                                          y: anchorY * area.height + value.translation.height), in: area)
                dragTranslation = .zero
                isDragging = false
                guard area.width > 0, area.height > 0 else { return }
                anchorX = Double(end.x / area.width)
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
