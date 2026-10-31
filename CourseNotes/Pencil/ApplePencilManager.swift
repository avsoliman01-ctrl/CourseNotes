import Observation
import PencilKit
import SwiftUI
import UIKit

// MARK: - Gesture preferences

enum DoubleTapBehavior: String, CaseIterable, Identifiable {
    case toggleEraser, previousTool, showPalette, followSystem, off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .toggleEraser: "Toggle Eraser"
        case .previousTool: "Switch to Previous Tool"
        case .showPalette: "Show Radial Palette"
        case .followSystem: "Follow System Setting"
        case .off: "Off"
        }
    }
}

enum SqueezeBehavior: String, CaseIterable, Identifiable {
    case radialPalette, cycleColors, cycleTools, followSystem, off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .radialPalette: "Show Radial Palette"
        case .cycleColors: "Cycle Black → Blue → Red → Highlight"
        case .cycleTools: "Cycle Pen → Highlighter → Lasso"
        case .followSystem: "Follow System Setting"
        case .off: "Off"
        }
    }
}

enum FingerDrawingPolicy: String, CaseIterable, Identifiable {
    case system, pencilOnly, anyInput

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Follow System Setting"
        case .pencilOnly: "Apple Pencil Only"
        case .anyInput: "Pencil and Finger"
        }
    }

    /// `.default` honors Settings › Apple Pencil › "Only Draw with Apple Pencil".
    var drawingPolicy: PKCanvasViewDrawingPolicy {
        switch self {
        case .system: .default
        case .pencilOnly: .pencilOnly
        case .anyInput: .anyInput
        }
    }
}

struct PencilPreferences: Equatable {
    var doubleTapBehavior: DoubleTapBehavior = .toggleEraser
    var squeezeBehavior: SqueezeBehavior = .radialPalette
    var fingerDrawing: FingerDrawingPolicy = .system
    var showsHoverReticle = true
    var hapticsEnabled = true

    private enum Key {
        static let doubleTap = "pencil.doubleTapBehavior"
        static let squeeze = "pencil.squeezeBehavior"
        static let finger = "pencil.fingerDrawing"
        static let reticle = "pencil.showsHoverReticle"
        static let haptics = "pencil.hapticsEnabled"
    }

    /// One key per value, so adding preferences later never invalidates what's already stored.
    static func load(from defaults: UserDefaults) -> PencilPreferences {
        var preferences = PencilPreferences()
        if let raw = defaults.string(forKey: Key.doubleTap), let value = DoubleTapBehavior(rawValue: raw) {
            preferences.doubleTapBehavior = value
        }
        if let raw = defaults.string(forKey: Key.squeeze), let value = SqueezeBehavior(rawValue: raw) {
            preferences.squeezeBehavior = value
        }
        if let raw = defaults.string(forKey: Key.finger), let value = FingerDrawingPolicy(rawValue: raw) {
            preferences.fingerDrawing = value
        }
        if defaults.object(forKey: Key.reticle) != nil {
            preferences.showsHoverReticle = defaults.bool(forKey: Key.reticle)
        }
        if defaults.object(forKey: Key.haptics) != nil {
            preferences.hapticsEnabled = defaults.bool(forKey: Key.haptics)
        }
        return preferences
    }

    func save(to defaults: UserDefaults) {
        defaults.set(doubleTapBehavior.rawValue, forKey: Key.doubleTap)
        defaults.set(squeezeBehavior.rawValue, forKey: Key.squeeze)
        defaults.set(fingerDrawing.rawValue, forKey: Key.finger)
        defaults.set(showsHoverReticle, forKey: Key.reticle)
        defaults.set(hapticsEnabled, forKey: Key.haptics)
    }
}

// MARK: - Gesture plumbing types

/// What a hardware gesture did; the canvas maps this to haptic intensity.
enum PencilGestureOutcome: Equatable {
    case ignored
    case toolChanged
    case paletteToggled
}

/// UIKit-independent mirror of `UIPencilInteraction.Phase`.
enum PencilSqueezePhase {
    case began, changed, ended, cancelled
}

/// Present while the squeeze palette is on screen. `anchor` is in canvas coordinates
/// (the pencil's hover location), or nil to center the palette.
struct RadialPaletteState: Equatable {
    var anchor: CGPoint?
}

/// Brief confirmation shown after a hardware gesture changes the tool.
struct PencilToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let symbolName: String
    let color: RGBAColor?
}

// MARK: - Manager

/// Owns the drawing-tool state machine and translates Apple Pencil hardware gestures
/// (double-tap, squeeze) into tool changes. Shared app-wide, so the tool you were using
/// follows you from note to note and across launches.
@MainActor
@Observable
final class ApplePencilManager {
    private(set) var activeTool: DrawingToolKind
    /// The inking tool that the eraser toggle (and color changes while erasing) return to.
    private(set) var lastInkingTool: DrawingToolKind
    /// Target of "switch to previous tool".
    private(set) var previousTool: DrawingToolKind
    private(set) var toolSettings: [DrawingToolKind: ToolSettings]
    private(set) var eraserMode: EraserMode

    private(set) var preferences: PencilPreferences
    private(set) var radialPalette: RadialPaletteState? = nil
    private(set) var toast: PencilToast? = nil

    private let defaults: UserDefaults
    private static let toolStateKey = "pencil.toolState"

    private struct SavedToolState: Codable {
        var activeTool: DrawingToolKind
        var lastInkingTool: DrawingToolKind
        var eraserMode: EraserMode
        var settings: [String: ToolSettings]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.toolStateKey)
            .flatMap { try? JSONDecoder().decode(SavedToolState.self, from: $0) }

        var settings: [DrawingToolKind: ToolSettings] = [:]
        for tool in DrawingToolKind.allCases {
            settings[tool] = saved?.settings[tool.rawValue]
                ?? ToolSettings(color: tool.defaultColor, width: tool.defaultWidth)
        }
        toolSettings = settings
        activeTool = saved?.activeTool ?? .pen
        lastInkingTool = saved?.lastInkingTool ?? .pen
        previousTool = saved?.lastInkingTool ?? .pen
        eraserMode = saved?.eraserMode ?? .object
        preferences = PencilPreferences.load(from: defaults)
        HapticEngine.shared.isEnabled = preferences.hapticsEnabled
    }

    // MARK: Derived state

    var currentConfiguration: ToolConfiguration {
        let settings = settings(for: activeTool)
        return ToolConfiguration(kind: activeTool, color: settings.color, width: settings.width, eraserMode: eraserMode)
    }

    /// The tool whose color the palette shows: the active ink, or the last ink while erasing/lassoing.
    var displayedInkTool: DrawingToolKind { activeTool.isInking ? activeTool : lastInkingTool }

    func settings(for tool: DrawingToolKind) -> ToolSettings {
        toolSettings[tool] ?? ToolSettings(color: tool.defaultColor, width: tool.defaultWidth)
    }

    // MARK: Preferences

    func updatePreferences(_ change: (inout PencilPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        guard updated != preferences else { return }
        preferences = updated
        preferences.save(to: defaults)
        HapticEngine.shared.isEnabled = updated.hapticsEnabled
    }

    /// Binding into one preference, for Settings controls.
    func preference<Value>(_ keyPath: WritableKeyPath<PencilPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { newValue in self.updatePreferences { $0[keyPath: keyPath] = newValue } }
        )
    }

    // MARK: Manual tool selection (palette)

    func select(_ tool: DrawingToolKind) {
        guard tool != activeTool else { return }
        previousTool = activeTool
        activeTool = tool
        if tool.isInking { lastInkingTool = tool }
        persistToolState()
    }

    func toggleEraser() {
        select(activeTool == .eraser ? lastInkingTool : .eraser)
    }

    func switchToPreviousTool() {
        select(previousTool)
    }

    /// Picking a color while erasing or lassoing switches back to ink, which is what users expect.
    func setColor(_ color: RGBAColor) {
        let tool = displayedInkTool
        var updated = settings(for: tool)
        updated.color = color
        toolSettings[tool] = updated
        select(tool)
        persistToolState()
    }

    func setWidth(_ width: CGFloat, for tool: DrawingToolKind) {
        let range = tool.widthRange
        var updated = settings(for: tool)
        updated.width = min(max(width, range.lowerBound), range.upperBound)
        toolSettings[tool] = updated
        persistToolState()
    }

    func setEraserMode(_ mode: EraserMode) {
        eraserMode = mode
        select(.eraser)
        persistToolState()
    }

    func apply(_ preset: InkPreset) {
        var updated = settings(for: preset.tool)
        updated.color = preset.color
        toolSettings[preset.tool] = updated
        select(preset.tool)
        persistToolState()
    }

    /// Black → Blue → Red → Highlight, continuing from whichever preset matches the current ink.
    func cycleColorPreset() {
        let presets = InkPreset.squeezeCycle
        let current = presets.firstIndex { $0.tool == activeTool && $0.color.isClose(to: settings(for: activeTool).color) }
        let next = presets[((current ?? -1) + 1) % presets.count]
        apply(next)
        showToast(next.name, symbol: next.tool.symbolName, color: next.color)
    }

    /// Pen → Highlighter → Lasso
    func cycleToolset() {
        let tools = InkPreset.toolsetCycle
        let current = tools.firstIndex(of: activeTool) ?? -1
        select(tools[(current + 1) % tools.count])
        announceActiveTool()
    }

    // MARK: Radial palette

    func toggleRadialPalette(at anchor: CGPoint?) {
        radialPalette = radialPalette == nil ? RadialPaletteState(anchor: anchor) : nil
    }

    func dismissRadialPalette() {
        if radialPalette != nil { radialPalette = nil }
    }

    func clearToast(id: UUID) {
        if toast?.id == id { toast = nil }
    }

    // MARK: Hardware gestures

    /// Apple Pencil double-tap. `location` is the hover position in canvas coordinates, if hovering.
    @discardableResult
    func handleDoubleTap(at location: CGPoint?) -> PencilGestureOutcome {
        let action: PencilAction = switch preferences.doubleTapBehavior {
        case .toggleEraser: .toggleEraser
        case .previousTool: .previousTool
        case .showPalette: .togglePalette
        case .followSystem: PencilAction(systemPreference: UIPencilInteraction.preferredTapAction)
        case .off: .nothing
        }
        return perform(action, at: location)
    }

    /// Apple Pencil Pro squeeze. Acts when the squeeze completes, as Apple's HIG recommends;
    /// `.began`/`.changed` are ignored so a squeeze that turns into a grip adjustment does nothing.
    @discardableResult
    func handleSqueeze(_ phase: PencilSqueezePhase, at location: CGPoint?) -> PencilGestureOutcome {
        guard phase == .ended else { return .ignored }
        let action: PencilAction = switch preferences.squeezeBehavior {
        case .radialPalette: .togglePalette
        case .cycleColors: .nextColorPreset
        case .cycleTools: .nextTool
        case .followSystem: PencilAction(systemPreference: UIPencilInteraction.preferredSqueezeAction)
        case .off: .nothing
        }
        return perform(action, at: location)
    }

    private enum PencilAction {
        case nothing, toggleEraser, previousTool, togglePalette, nextColorPreset, nextTool

        /// Maps the user's choice in Settings › Apple Pencil onto this app's actions.
        init(systemPreference: UIPencilPreferredAction) {
            switch systemPreference {
            case .switchEraser: self = .toggleEraser
            case .switchPrevious: self = .previousTool
            case .showColorPalette, .showInkAttributes, .showContextualPalette: self = .togglePalette
            case .ignore, .runSystemShortcut: self = .nothing
            @unknown default: self = .togglePalette
            }
        }
    }

    private func perform(_ action: PencilAction, at location: CGPoint?) -> PencilGestureOutcome {
        switch action {
        case .nothing:
            return .ignored
        case .toggleEraser:
            dismissRadialPalette()
            toggleEraser()
            announceActiveTool()
            return .toolChanged
        case .previousTool:
            dismissRadialPalette()
            switchToPreviousTool()
            announceActiveTool()
            return .toolChanged
        case .togglePalette:
            toggleRadialPalette(at: location)
            return .paletteToggled
        case .nextColorPreset:
            dismissRadialPalette()
            cycleColorPreset()
            return .toolChanged
        case .nextTool:
            dismissRadialPalette()
            cycleToolset()
            return .toolChanged
        }
    }

    static func describe(_ action: UIPencilPreferredAction) -> String {
        switch action {
        case .ignore: "Off"
        case .switchEraser: "Switch Between Current Tool and Eraser"
        case .switchPrevious: "Switch Between Current Tool and Last Used"
        case .showColorPalette: "Show Color Palette"
        case .showInkAttributes: "Show Ink Attributes"
        case .showContextualPalette: "Show Tool Palette"
        case .runSystemShortcut: "Run a Shortcut"
        @unknown default: "Custom"
        }
    }

    // MARK: Private

    private func announceActiveTool() {
        let tool = activeTool
        if tool == .eraser {
            showToast(eraserMode.displayName, symbol: eraserMode.symbolName, color: nil)
        } else {
            showToast(tool.displayName, symbol: tool.symbolName, color: tool.isInking ? settings(for: tool).color : nil)
        }
    }

    private func showToast(_ title: String, symbol: String, color: RGBAColor?) {
        toast = PencilToast(title: title, symbolName: symbol, color: color)
    }

    private func persistToolState() {
        let state = SavedToolState(
            activeTool: activeTool,
            lastInkingTool: lastInkingTool,
            eraserMode: eraserMode,
            settings: Dictionary(uniqueKeysWithValues: toolSettings.map { ($0.key.rawValue, $0.value) })
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.toolStateKey)
        }
    }
}
