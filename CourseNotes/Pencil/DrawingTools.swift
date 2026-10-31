import PencilKit
import SwiftUI
import UIKit

enum DrawingToolKind: String, Codable, CaseIterable, Identifiable {
    case pen, fountainPen, pencil, highlighter, monoline, eraser, lasso

    var id: String { rawValue }

    static let inkingTools: [DrawingToolKind] = [.pen, .fountainPen, .pencil, .highlighter, .monoline]

    var displayName: String {
        switch self {
        case .pen: "Pen"
        case .fountainPen: "Fountain Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .monoline: "Monoline"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .fountainPen: "signature"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .monoline: "scribble"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }

    var isInking: Bool { inkType != nil }

    /// PencilKit ink. Pencil and fountain pen respond to tilt; fountain pen and highlighter
    /// follow Apple Pencil Pro barrel roll automatically on iPadOS 17.5+.
    var inkType: PKInkingTool.InkType? {
        switch self {
        case .pen: .pen
        case .fountainPen: .fountainPen
        case .pencil: .pencil
        case .highlighter: .marker
        case .monoline: .monoline
        case .eraser, .lasso: nil
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen, .fountainPen, .monoline: 1...20
        case .pencil: 2...16
        case .highlighter: 6...36
        case .eraser: 4...80
        case .lasso: 1...1
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .pen, .monoline: 3
        case .fountainPen, .pencil: 4
        case .highlighter: 18
        case .eraser: 24
        case .lasso: 1
        }
    }

    var defaultColor: RGBAColor { self == .highlighter ? .highlightYellow : .black }

    /// Fine / medium / bold quick picks for the palettes, rounded to half points.
    var widthPresets: [CGFloat] {
        let span = widthRange.upperBound - widthRange.lowerBound
        return [0.1, 0.35, 0.75].map { ((widthRange.lowerBound + span * $0) * 2).rounded() / 2 }
    }
}

enum EraserMode: String, Codable, CaseIterable, Identifiable {
    /// Removes whole strokes.
    case object
    /// Erases only the pixels it passes over, with an adjustable width.
    case pixel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .object: "Object Eraser"
        case .pixel: "Pixel Eraser"
        }
    }

    var symbolName: String {
        switch self {
        case .object: "eraser"
        case .pixel: "eraser.line.dashed"
        }
    }
}

/// Codable color, resolved in light appearance (ink sits on white paper).
struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: UIColor) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if !resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &a)
            (r, g, b) = (white, white, white)
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(uiColor: uiColor) }

    /// Colors from the system picker carry floating-point noise; compare with a tolerance.
    func isClose(to other: RGBAColor) -> Bool {
        abs(red - other.red) < 0.01 && abs(green - other.green) < 0.01
            && abs(blue - other.blue) < 0.01 && abs(alpha - other.alpha) < 0.01
    }

    static let black = RGBAColor(red: 0.08, green: 0.08, blue: 0.10)
    static let blue = RGBAColor(red: 0.11, green: 0.36, blue: 0.85)
    static let red = RGBAColor(red: 0.85, green: 0.18, blue: 0.18)
    static let green = RGBAColor(red: 0.13, green: 0.58, blue: 0.32)
    static let purple = RGBAColor(red: 0.50, green: 0.25, blue: 0.80)
    static let orange = RGBAColor(red: 0.95, green: 0.50, blue: 0.10)

    static let highlightYellow = RGBAColor(red: 1.00, green: 0.88, blue: 0.20)
    static let highlightGreen = RGBAColor(red: 0.55, green: 0.92, blue: 0.45)
    static let highlightPink = RGBAColor(red: 1.00, green: 0.55, blue: 0.75)
    static let highlightBlue = RGBAColor(red: 0.45, green: 0.78, blue: 1.00)
    static let highlightOrange = RGBAColor(red: 1.00, green: 0.70, blue: 0.35)
}

enum InkPalette {
    static let pen: [RGBAColor] = [.black, .blue, .red, .green, .purple, .orange]
    static let highlighter: [RGBAColor] = [.highlightYellow, .highlightGreen, .highlightPink, .highlightBlue, .highlightOrange]

    static func colors(for tool: DrawingToolKind) -> [RGBAColor] {
        tool == .highlighter ? highlighter : pen
    }
}

struct ToolSettings: Codable, Hashable {
    var color: RGBAColor
    var width: CGFloat
}

/// Everything needed to build a `PKTool`. Equatable so the canvas only swaps tools when something changed
/// (re-assigning `PKCanvasView.tool` on every SwiftUI update would be wasteful).
struct ToolConfiguration: Equatable {
    var kind: DrawingToolKind
    var color: RGBAColor
    var width: CGFloat
    var eraserMode: EraserMode

    var pkTool: any PKTool {
        switch kind {
        case .eraser:
            if eraserMode == .object {
                return PKEraserTool(.vector)
            }
            return PKEraserTool(.fixedWidthBitmap, width: width)
        case .lasso:
            return PKLassoTool()
        default:
            return PKInkingTool(kind.inkType ?? .pen, color: color.uiColor, width: width)
        }
    }
}

/// Presets used by the squeeze gesture's quick-cycle modes.
struct InkPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let tool: DrawingToolKind
    let color: RGBAColor

    /// Black → Blue → Red → Highlight
    static let squeezeCycle: [InkPreset] = [
        InkPreset(id: "black", name: "Black Pen", tool: .pen, color: .black),
        InkPreset(id: "blue", name: "Blue Pen", tool: .pen, color: .blue),
        InkPreset(id: "red", name: "Red Pen", tool: .pen, color: .red),
        InkPreset(id: "highlight", name: "Highlighter", tool: .highlighter, color: .highlightYellow)
    ]

    /// Pen → Highlighter → Lasso
    static let toolsetCycle: [DrawingToolKind] = [.pen, .highlighter, .lasso]
}
