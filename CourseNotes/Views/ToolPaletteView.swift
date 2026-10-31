import SwiftUI

/// Floating palette: tools, ink colors, custom color, stroke width, undo/redo.
/// Falls back to a compact layout in narrow windows (Split View, Slide Over, Stage Manager).
struct ToolPaletteView: View {
    let controller: CanvasController

    var body: some View {
        ViewThatFits(in: .horizontal) {
            PaletteBar(controller: controller, isCompact: false)
            PaletteBar(controller: controller, isCompact: true)
        }
    }
}

private struct PaletteBar: View {
    let controller: CanvasController
    let isCompact: Bool

    @Environment(ApplePencilManager.self) private var pencil
    @State private var showingWidth = false
    @State private var showingEraserOptions = false

    var body: some View {
        HStack(spacing: 2) {
            if isCompact {
                toolMenu
            } else {
                ForEach(DrawingToolKind.inkingTools) { tool in
                    toolButton(tool)
                }
                separator
                eraserButton
                toolButton(.lasso)
            }
            separator
            colorControls
            separator
            widthButton
            separator
            undoRedo
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .fixedSize()
    }

    // MARK: Tools

    private func toolButton(_ tool: DrawingToolKind) -> some View {
        let isActive = pencil.activeTool == tool
        return Button {
            pencil.select(tool)
        } label: {
            ToolIcon(symbol: tool.symbolName, isActive: isActive,
                     inkColor: tool.isInking ? pencil.settings(for: tool).color.color : nil)
        }
        .buttonStyle(.plain)
        .help(tool.displayName)
        .accessibilityLabel(tool.displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var eraserButton: some View {
        let isActive = pencil.activeTool == .eraser
        return Button {
            if isActive {
                showingEraserOptions = true
            } else {
                pencil.select(.eraser)
            }
        } label: {
            ToolIcon(symbol: pencil.eraserMode.symbolName, isActive: isActive)
        }
        .buttonStyle(.plain)
        .help("Eraser (tap again for options)")
        .accessibilityLabel(pencil.eraserMode.displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .popover(isPresented: $showingEraserOptions) {
            EraserOptionsView()
                .presentationCompactAdaptation(.popover)
        }
    }

    private var toolMenu: some View {
        let active = pencil.activeTool
        return Menu {
            ForEach(DrawingToolKind.allCases) { tool in
                Button {
                    pencil.select(tool)
                } label: {
                    Label(tool.displayName, systemImage: tool.symbolName)
                }
            }
            Divider()
            Picker("Eraser Mode", selection: eraserModeBinding) {
                ForEach(EraserMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                }
            }
        } label: {
            ToolIcon(symbol: active == .eraser ? pencil.eraserMode.symbolName : active.symbolName, isActive: true)
        }
        .accessibilityLabel("Tool: \(active.displayName)")
    }

    private var eraserModeBinding: Binding<EraserMode> {
        Binding(get: { pencil.eraserMode }, set: { pencil.setEraserMode($0) })
    }

    // MARK: Colors

    @ViewBuilder
    private var colorControls: some View {
        let tool = pencil.displayedInkTool
        let current = pencil.settings(for: tool).color
        let palette = InkPalette.colors(for: tool)
        let swatches = isCompact ? Array(palette.prefix(3)) : palette

        ForEach(swatches, id: \.self) { color in
            Button {
                pencil.setColor(color)
            } label: {
                ColorDot(color: color, isSelected: pencil.activeTool.isInking && color.isClose(to: current))
            }
            .buttonStyle(.plain)
        }
        ColorPicker("Custom Color", selection: customColorBinding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 34, height: 38)
    }

    /// The system color picker edits the color of the ink tool (switching back to it if erasing).
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { pencil.settings(for: pencil.displayedInkTool).color.color },
            set: { pencil.setColor(RGBAColor(UIColor($0))) }
        )
    }

    // MARK: Width

    /// Lasso and the object eraser have no width, so the control adjusts the last ink instead.
    private var widthTarget: DrawingToolKind {
        switch pencil.activeTool {
        case .lasso: pencil.lastInkingTool
        case .eraser where pencil.eraserMode == .object: pencil.lastInkingTool
        default: pencil.activeTool
        }
    }

    private var widthButton: some View {
        let tool = widthTarget
        let settings = pencil.settings(for: tool)
        let size = dotDiameter(for: settings.width, of: tool)
        return Button {
            showingWidth = true
        } label: {
            Circle()
                .fill(tool == .eraser ? Color.secondary : settings.color.color)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .frame(width: size, height: size)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stroke Width")
        .accessibilityLabel("Stroke width")
        .accessibilityValue(String(format: "%.1f points", Double(settings.width)))
        .popover(isPresented: $showingWidth) {
            WidthOptionsView(tool: tool)
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Undo / redo

    private var undoRedo: some View {
        HStack(spacing: 2) {
            Button {
                controller.undo()
            } label: {
                ToolIcon(symbol: "arrow.uturn.backward", isActive: false)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canUndo)
            .opacity(controller.canUndo ? 1 : 0.35)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")
            .accessibilityLabel("Undo")

            Button {
                controller.redo()
            } label: {
                ToolIcon(symbol: "arrow.uturn.forward", isActive: false)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canRedo)
            .opacity(controller.canRedo ? 1 : 0.35)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo")
            .accessibilityLabel("Redo")
        }
    }

    private var separator: some View {
        Divider()
            .frame(height: 24)
            .padding(.horizontal, 4)
    }
}

/// 6–24 pt dot that grows with the stroke width.
func dotDiameter(for width: CGFloat, of tool: DrawingToolKind) -> CGFloat {
    let range = tool.widthRange
    let fraction = (width - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)
    return 6 + min(max(fraction, 0), 1) * 18
}

private struct ToolIcon: View {
    let symbol: String
    let isActive: Bool
    var inkColor: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 38, height: 38)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background {
                if isActive { Circle().fill(Color.accentColor) }
            }
            .overlay(alignment: .bottom) {
                if let inkColor {
                    Capsule()
                        .fill(inkColor)
                        .frame(width: 14, height: 3)
                        .offset(y: -3)
                }
            }
            .contentShape(Circle())
    }
}

private struct ColorDot: View {
    let color: RGBAColor
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .padding(3)
            .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
            .frame(width: 34, height: 38)
            .contentShape(Rectangle())
            .accessibilityLabel("Color")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct WidthOptionsView: View {
    let tool: DrawingToolKind

    @Environment(ApplePencilManager.self) private var pencil

    var body: some View {
        let range = tool.widthRange
        let width = pencil.settings(for: tool).width

        VStack(alignment: .leading, spacing: 16) {
            Text("\(tool.displayName) Width")
                .font(.headline)

            HStack(spacing: 14) {
                ForEach(tool.widthPresets, id: \.self) { preset in
                    Button {
                        pencil.setWidth(preset, for: tool)
                    } label: {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: dotDiameter(for: preset, of: tool), height: dotDiameter(for: preset, of: tool))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(abs(preset - width) < 0.25 ? Color.accentColor.opacity(0.2) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: "%.1f points", Double(preset)))
                }
            }

            Slider(value: Binding(get: { Double(width) }, set: { pencil.setWidth(CGFloat($0), for: tool) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))

            Text(String(format: "%.1f pt", Double(width)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 280)
    }
}

private struct EraserOptionsView: View {
    @Environment(ApplePencilManager.self) private var pencil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Eraser")
                .font(.headline)

            Picker("Mode", selection: Binding(get: { pencil.eraserMode }, set: { pencil.setEraserMode($0) })) {
                ForEach(EraserMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if pencil.eraserMode == .pixel {
                let range = DrawingToolKind.eraser.widthRange
                let width = pencil.settings(for: .eraser).width
                Slider(value: Binding(get: { Double(width) }, set: { pencil.setWidth(CGFloat($0), for: .eraser) }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
                Text(String(format: "%.0f pt", Double(width)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Removes whole strokes it touches. Double-tap Apple Pencil to switch back to ink.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
