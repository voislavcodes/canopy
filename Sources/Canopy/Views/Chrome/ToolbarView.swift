import SwiftUI

struct ToolbarView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var transportState: TransportState

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

            TransportView(transportState: transportState)

            Spacer()

            // Dirty indicator
            if projectState.isDirty {
                Circle()
                    .fill(CanopyColors.chromeText.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
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
