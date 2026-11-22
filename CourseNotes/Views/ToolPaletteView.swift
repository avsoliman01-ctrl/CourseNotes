import SwiftUI

/// Floating palette: tools, ink colors, custom color, stroke width, undo/redo.
/// Falls back to a compact layout in narrow windows (Split View, Slide Over, Stage Manager).
struct ToolPaletteView: View {
    let controller: CanvasController
    /// Vertical when the palette is docked against a side edge (always the compact tool set).
    var axis: Axis = .horizontal

    var body: some View {
        if axis == .vertical {
            PaletteBar(controller: controller, isCompact: true, axis: .vertical)
        } else {
            ViewThatFits(in: .horizontal) {
                PaletteBar(controller: controller, isCompact: false, axis: .horizontal)
                PaletteBar(controller: controller, isCompact: true, axis: .horizontal)
            }
        }
    }
}

private struct PaletteBar: View {
    let controller: CanvasController
    let isCompact: Bool
    let axis: Axis

    @Environment(ApplePencilManager.self) private var pencil
    @Environment(\.paperAppearance) private var paperAppearance
    @State private var showingWidth = false
    @State private var showingEraserOptions = false

    var body: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
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
        // Background, drag handle and pin/hide controls are added by FloatingPalette.
        .fixedSize()
    }

    // MARK: Tools

    private func toolButton(_ tool: DrawingToolKind) -> some View {
        let isActive = pencil.activeTool == tool
        return Button {
            pencil.select(tool)
        } label: {
            ToolIcon(symbol: tool.symbolName, isActive: isActive,
                     inkColor: tool.isInking ? pencil.settings(for: tool).color.displayedColor(on: paperAppearance) : nil)
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

    /// The user's colors. Long-press one to replace it with the current ink, reorder or remove it;
    /// + adds the current ink (pick it first with the color wheel).
    @ViewBuilder
    private var colorControls: some View {
        let tool = pencil.displayedInkTool
        let current = pencil.settings(for: tool).color
        let palette = pencil.swatches(for: tool)
        let swatches = isCompact ? Array(palette.prefix(3)) : palette

        ForEach(Array(swatches.enumerated()), id: \.offset) { index, color in
            Button {
                pencil.setColor(color)
            } label: {
                ColorDot(color: color, isSelected: pencil.activeTool.isInking && color.isClose(to: current))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    pencil.replaceSwatch(at: index, with: current, for: tool)
                } label: {
                    Label("Replace with Current Color", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(color.isClose(to: current))
                Button {
                    pencil.moveSwatch(at: index, by: -1, for: tool)
                } label: {
                    Label("Move Left", systemImage: "arrow.left")
                }
                .disabled(index == 0)
                Button {
                    pencil.moveSwatch(at: index, by: 1, for: tool)
                } label: {
                    Label("Move Right", systemImage: "arrow.right")
                }
                .disabled(index == palette.count - 1)
                Divider()
                Button(role: .destructive) {
                    pencil.removeSwatch(at: index, for: tool)
                } label: {
                    Label("Remove Color", systemImage: "trash")
                }
                .disabled(palette.count <= 1)
            }
        }
        ColorPicker("Custom Color", selection: customColorBinding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 34, height: 38)
        if !isCompact {
            Button {
                pencil.addSwatch(current, for: tool)
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!pencil.canAddSwatch(current, for: tool))
            .opacity(pencil.canAddSwatch(current, for: tool) ? 1 : 0.35)
            .help("Add the current color to the toolbar")
            .accessibilityLabel("Add current color to toolbar")
        }
    }

    /// The system color picker edits the color of the ink tool (switching back to it if erasing).
    /// On dark paper it shows and takes colors as they appear there.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { pencil.settings(for: pencil.displayedInkTool).color.displayedColor(on: paperAppearance) },
            set: { pencil.setColor(RGBAColor.stored(fromDisplayed: UIColor($0), on: paperAppearance)) }
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
                .fill(tool == .eraser ? Color.secondary : settings.color.displayedColor(on: paperAppearance))
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
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
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
            .frame(width: axis == .vertical ? 24 : nil, height: axis == .vertical ? nil : 24)
            .padding(axis == .vertical ? .vertical : .horizontal, 4)
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

    @Environment(\.paperAppearance) private var paperAppearance

    var body: some View {
        Circle()
            .fill(color.displayedColor(on: paperAppearance))
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

            Divider()

            Text("Line Style")
                .font(.headline)
            Picker("Line Style", selection: Binding(get: { pencil.lineStyle }, set: { pencil.setLineStyle($0) })) {
                ForEach(StrokeLineStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            Text("Dashed and dotted apply to new strokes and corrected shapes when you pause. To change existing ink, select it with the lasso.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 300)
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
