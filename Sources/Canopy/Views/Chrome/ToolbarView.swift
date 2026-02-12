import SwiftUI

struct ToolbarView: View {
    @ObservedObject var projectState: ProjectState

    @State private var isEditingName = false
    @State private var editedName = ""

    var body: some View {
        HStack {
            // Project name
            if isEditingName {
                TextField("Project Name", text: $editedName, onCommit: {
                    projectState.project.name = editedName
                    projectState.isDirty = true
                    isEditingName = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(CanopyColors.chromeTextBright)
                .frame(width: 160)
            } else {
                Text(projectState.project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(CanopyColors.chromeTextBright)
                    .onTapGesture(count: 2) {
                        editedName = projectState.project.name
                        isEditingName = true
                    }
            }

            Spacer()

            TransportPlaceholder()

            Spacer()

            // BPM display
            Text("\(Int(projectState.project.bpm)) BPM")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CanopyColors.chromeBackground)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(CanopyColors.chromeBorder),
            alignment: .bottom
        )
    }
}
