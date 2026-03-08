import SwiftUI

/// Sizing constants for node visualization.
enum NodeMetrics {
    static let coreRadius: CGFloat = 14
    static let midiShapeMinRadius: CGFloat = 18
    static let midiShapeMaxRadius: CGFloat = 42
    static let ringRadius: CGFloat = 50
    static let tickLength: CGFloat = 6
    static let playheadDotRadius: CGFloat = 4
    static let frameWidth: CGFloat = 130
    static let frameHeight: CGFloat = 140
}

struct NodeView: View {
    let node: Node
    let isSelected: Bool
    let isPlaying: Bool
    let nodeColor: Color
    var showGlow: Bool = true
    var showLabels: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Layer 1: Selection glow (hugs outer ring)
                if isSelected && showGlow {
                    NodeGlowEffect(radius: NodeMetrics.ringRadius, color: nodeColor)
                }

                // Layer 2: Playback ring with ticks and playhead
                NodePlaybackRing(
                    nodeID: node.id,
                    lengthInBeats: node.sequence.lengthInBeats,
                    color: nodeColor,
                    isPlaying: isPlaying,
                    isSelected: isSelected
                )

                // Layer 3: MIDI fingerprint shape
                MIDIShapeView(
                    notes: node.sequence.notes,
                    lengthInBeats: node.sequence.lengthInBeats,
                    color: nodeColor,
                    params: MIDIShapeParams(from: node.sequence)
                )

                // Layer 4: Core dot
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [nodeColor, nodeColor.opacity(0.8)],
                            center: .center,
                            startRadius: 0,
                            endRadius: NodeMetrics.coreRadius
                        )
                    )
                    .frame(
                        width: NodeMetrics.coreRadius * 2,
                        height: NodeMetrics.coreRadius * 2
                    )
            }

            // Labels below node
            VStack(spacing: 2) {
                Text(node.name.lowercased())
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(nodeColor.opacity(0.7))

                Text("\(Int(node.sequence.lengthInBeats))b")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(nodeColor.opacity(0.45))
            }
            .opacity(showLabels ? 1 : 0)
        }
        .frame(width: NodeMetrics.frameWidth, height: NodeMetrics.frameHeight)
        .contentShape(Rectangle())
        .opacity(node.isMuted ? 0.35 : 1.0)
        .position(x: node.position.x, y: node.position.y)
    }
}
