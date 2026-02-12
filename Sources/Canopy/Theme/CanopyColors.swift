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
}
