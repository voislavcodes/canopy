import SwiftUI

struct ToolbarView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var transportState: TransportState

    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showScalePicker = false

    private var currentTreeScale: MusicalKey {
        let tree = projectState.project.trees.first
        return tree?.scale ?? projectState.project.globalKey
    }

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

            // Tree scale display
            Button(action: { showScalePicker.toggle() }) {
                Text(currentTreeScale.displayName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(CanopyColors.chromeBackground.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(CanopyColors.chromeBorder.opacity(0.4), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showScalePicker) {
                VStack(spacing: 8) {
                    ScalePickerView(
                        selectedKey: Binding(
                            get: { projectState.project.trees.first?.scale },
                            set: { newKey in
                                if projectState.project.trees.count > 0 {
                                    projectState.project.trees[0].scale = newKey
                                    projectState.isDirty = true
                                }
                            }
                        ),
                        inheritedKey: projectState.project.globalKey,
                        label: "Tree Scale"
                    )
                }
                .padding(12)
                .frame(width: 200)
                .background(CanopyColors.bloomPanelBackground)
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
