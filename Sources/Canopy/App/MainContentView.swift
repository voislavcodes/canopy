import SwiftUI

struct MainContentView: View {
    @ObservedObject var projectState: ProjectState
    @StateObject private var canvasState = CanvasState()

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(projectState: projectState)
            CanopyCanvasView(projectState: projectState, canvasState: canvasState)
        }
    }
}
