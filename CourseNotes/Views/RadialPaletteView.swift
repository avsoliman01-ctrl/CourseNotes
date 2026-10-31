import SwiftUI

/// Apple Pencil Pro squeeze palette: tools on the inner ring, colors and stroke widths on the
/// outer ring, centered under the hovering pencil tip (or the canvas center when not hovering).
struct RadialPaletteView: View {
    /// In the canvas container's coordinate space.
    let anchor: CGPoint?

    @Environment(ApplePencilManager.self) private var pencil

    private let diameter: CGFloat = 316
    private let innerRadius: CGFloat = 70
    private let outerRadius: CGFloat = 128

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.06)
                    .contentShape(Rectangle())
                    .onTapGesture { pencil.dismissRadialPalette() }
                    .accessibilityLabel("Close palette")

                palette
                    .position(center(in: proxy.size))
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    /// Keeps the whole palette on screen near the edges.
    private func center(in size: CGSize) -> CGPoint {
        let margin = diameter / 2 + 8
        let proposed = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(x: min(max(proposed.x, margin), max(margin, size.width - margin)),
                       y: min(max(proposed.y, margin), max(margin, size.height - margin)))
    }

    private var palette: some View {
        let tools = DrawingToolKind.allCases
        let inkTool = pencil.displayedInkTool
        let currentColor = pencil.settings(for: inkTool).color
        let colors = InkPalette.colors(for: inkTool)
        let widths = inkTool.widthPresets
        let outerCount = colors.count + widths.count

        return ZStack {
            Circle()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
            Circle()
                .strokeBorder(.quaternary, lineWidth: 1)
                .frame(width: innerRadius + outerRadius, height: innerRadius + outerRadius)

            ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                toolButton(tool)
                    .offset(offset(index, of: tools.count, radius: innerRadius))
            }
            ForEach(Array(colors.enumerated()), id: \.element) { index, color in
                colorButton(color, isSelected: pencil.activeTool.isInking && color.isClose(to: currentColor))
                    .offset(offset(index, of: outerCount, radius: outerRadius))
            }
            ForEach(Array(widths.enumerated()), id: \.element) { index, width in
                widthButton(width, tool: inkTool)
                    .offset(offset(colors.count + index, of: outerCount, radius: outerRadius))
            }

            Button {
                pencil.dismissRadialPalette()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.thinMaterial))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close palette")
        }
        .frame(width: diameter, height: diameter)
    }

    /// Item positions clockwise from 12 o'clock.
    private func offset(_ index: Int, of count: Int, radius: CGFloat) -> CGSize {
        let angle = -Double.pi / 2 + Double(index) / Double(max(count, 1)) * 2 * Double.pi
        return CGSize(width: CGFloat(cos(angle)) * radius, height: CGFloat(sin(angle)) * radius)
    }

    private func toolButton(_ tool: DrawingToolKind) -> some View {
        let isActive = pencil.activeTool == tool
        return Button {
            pencil.select(tool)
            HapticEngine.shared.selectionChanged(at: anchor)
        } label: {
            Image(systemName: tool == .eraser ? pencil.eraserMode.symbolName : tool.symbolName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .background(Circle().fill(isActive ? Color.accentColor : Color(uiColor: .secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func colorButton(_ color: RGBAColor, isSelected: Bool) -> some View {
        Button {
            pencil.setColor(color)
            HapticEngine.shared.selectionChanged(at: anchor)
            pencil.dismissRadialPalette()
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 2)
                .padding(4)
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ink color")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func widthButton(_ width: CGFloat, tool: DrawingToolKind) -> some View {
        let isSelected = abs(pencil.settings(for: tool).width - width) < 0.25
        let dot = dotDiameter(for: width, of: tool)
        return Button {
            pencil.setWidth(width, for: tool)
            HapticEngine.shared.selectionChanged(at: anchor)
        } label: {
            Circle()
                .fill(Color.primary)
                .frame(width: dot, height: dot)
                .frame(width: 40, height: 40)
                .background(Circle().fill(isSelected ? Color.accentColor.opacity(0.22) : Color(uiColor: .secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: "Width %.1f points", Double(width)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Eraser", "Blue Pen" … shown briefly after a double-tap or squeeze changes the tool.
struct PencilToastView: View {
    let toast: PencilToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbolName)
            if let color = toast.color {
                Circle()
                    .fill(color.color)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
            }
            Text(toast.title)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
