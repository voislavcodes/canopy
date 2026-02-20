import SwiftUI

enum CanopyColors {
    // Canvas
    static let canvasBackground = Color(red: 0.055, green: 0.065, blue: 0.06)
    static let canvasBorder = Color(red: 0.2, green: 0.25, blue: 0.2)
    static let dotGrid = Color(red: 0.15, green: 0.18, blue: 0.16)

    // Nodes
    static let nodeFill = Color(red: 0.35, green: 0.85, blue: 0.5)
    static let nodeStroke = Color(red: 0.25, green: 0.4, blue: 0.3)
    static let nodeLabel = Color(red: 0.55, green: 0.7, blue: 0.6)
    static let glowColor = Color(red: 0.3, green: 0.9, blue: 0.45)

    // Bloom
    static let bloomZone = Color(red: 0.06, green: 0.08, blue: 0.07)
    static let bloomPanelBackground = Color(red: 0.07, green: 0.09, blue: 0.08)
    static let bloomPanelBorder = Color(red: 0.2, green: 0.3, blue: 0.22)
    static let bloomConnector = Color(red: 0.2, green: 0.3, blue: 0.22)

    // Chrome (toolbar, keyboard)
    static let chromeBackground = Color(red: 0.055, green: 0.065, blue: 0.06)
    static let chromeBorder = Color(red: 0.15, green: 0.2, blue: 0.16)
    static let chromeText = Color(red: 0.45, green: 0.55, blue: 0.48)
    static let chromeTextBright = Color(red: 0.7, green: 0.8, blue: 0.72)
    static let transportIcon = Color(red: 0.4, green: 0.5, blue: 0.42)

    // Sequencer grid
    static let gridCellActive = Color(red: 0.25, green: 0.65, blue: 0.35)
    static let gridCellInactive = Color(red: 0.1, green: 0.13, blue: 0.11)
    static let gridCellBeat = Color(red: 0.12, green: 0.16, blue: 0.13)

    // Branch lines
    static let branchLine = Color(red: 0.25, green: 0.4, blue: 0.3)

    // Node type colors
    static let nodeSeed = Color(red: 0.35, green: 0.85, blue: 0.5)       // Green
    static let nodeMelodic = Color(red: 0.35, green: 0.6, blue: 0.9)     // Blue
    static let nodeHarmonic = Color(red: 0.6, green: 0.4, blue: 0.85)    // Purple
    static let nodeRhythmic = Color(red: 0.9, green: 0.55, blue: 0.25)   // Orange
    static let nodeEffect = Color(red: 0.7, green: 0.7, blue: 0.4)       // Yellow-olive
    static let nodeGroup = Color(red: 0.5, green: 0.5, blue: 0.55)       // Gray

    // Preset-specific colors (pad, arp, fx, west don't map to existing NodeType colors)
    static let nodePad = Color(red: 0.3, green: 0.75, blue: 0.65)        // Teal
    static let nodeArp = Color(red: 0.35, green: 0.8, blue: 0.85)        // Cyan
    static let nodeFX = Color(red: 0.85, green: 0.45, blue: 0.65)        // Pink
    static let nodeWest = Color(red: 0.506, green: 0.549, blue: 0.972)   // Indigo #818CF8
    static let nodeFlow = Color(red: 0.3, green: 0.75, blue: 0.85)     // Teal-cyan for fluid
    static let nodeTide = Color(red: 0.2, green: 0.65, blue: 0.75)     // Ocean teal for spectral
    static let nodeSwarm = Color(red: 0.5, green: 0.9, blue: 0.2)     // Lime green for emergent

    /// Map a PresetColor to a SwiftUI Color.
    static func presetColor(_ pc: PresetColor) -> Color {
        switch pc {
        case .blue:   return nodeMelodic
        case .purple: return nodeHarmonic
        case .orange: return nodeRhythmic
        case .green:  return nodePad
        case .cyan:   return nodeArp
        case .pink:   return nodeFX
        case .indigo: return nodeWest
        case .lime:   return nodeSwarm
        }
    }
}
