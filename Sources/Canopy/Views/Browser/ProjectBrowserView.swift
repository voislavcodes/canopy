import SwiftUI

struct ProjectBrowserView: View {
    var onNewProject: () -> Void
    var onOpenProject: (URL) -> Void
    var onOpenFile: () -> Void

    @State private var projects: [ProjectInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Text("canopy")
                    .font(.system(size: 28, weight: .light, design: .monospaced))
                    .foregroundColor(CanopyColors.glowColor)

                Button(action: onNewProject) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("New Project")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(CanopyColors.glowColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CanopyColors.glowColor.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(CanopyColors.glowColor.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 32)
            .padding(.bottom, 20)

            // Project list
            if projects.isEmpty {
                Spacer()
                Text("No projects yet")
                    .font(.system(size: 13))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(projects) { info in
                            ProjectRowView(
                                info: info,
                                onOpen: { onOpenProject(info.url) },
                                onRename: { newName in
                                    if let _ = ProjectPersistenceService.renameProject(at: info.url, to: newName) {
                                        refreshProjects()
                                    }
                                },
                                onDuplicate: {
                                    let _ = ProjectPersistenceService.duplicateProject(at: info.url)
                                    refreshProjects()
                                },
                                onShowInFinder: {
                                    ProjectPersistenceService.revealInFinder(url: info.url)
                                },
                                onDelete: {
                                    ProjectPersistenceService.deleteProject(at: info.url)
                                    refreshProjects()
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Footer
            HStack {
                Spacer()
                Button(action: onOpenFile) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("Open File...")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(CanopyColors.chromeText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(CanopyColors.chromeBorder.opacity(0.3)),
                alignment: .top
            )
        }
        .background(CanopyColors.canvasBackground)
        .onAppear { refreshProjects() }
    }

    private func refreshProjects() {
        projects = ProjectPersistenceService.listProjects()
    }
}
