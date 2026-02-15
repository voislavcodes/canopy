import SwiftUI

struct ProjectRowView: View {
    let info: ProjectInfo
    var onOpen: () -> Void
    var onRename: (String) -> Void
    var onDuplicate: () -> Void
    var onShowInFinder: () -> Void
    var onDelete: () -> Void

    @State private var isRenaming = false
    @State private var editedName = ""
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                // Preset color dots (up to 6)
                HStack(spacing: 3) {
                    let colors = Array(info.presetColors.prefix(6))
                    ForEach(0..<colors.count, id: \.self) { i in
                        Circle()
                            .fill(CanopyColors.presetColor(colors[i]))
                            .frame(width: 6, height: 6)
                    }
                    // Pad to consistent width when fewer than 6 dots
                    if colors.count < 6 {
                        Spacer().frame(width: CGFloat(6 - colors.count) * 9)
                    }
                }
                .frame(width: 60, alignment: .leading)

                // Project name (or rename field)
                if isRenaming {
                    TextField("Name", text: $editedName, onCommit: {
                        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            onRename(trimmed)
                        }
                        isRenaming = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(CanopyColors.chromeTextBright)
                    .onExitCommand { isRenaming = false }
                } else {
                    Text(info.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(CanopyColors.chromeTextBright)
                        .lineLimit(1)
                }

                Spacer()

                // Relative time
                Text(relativeTime(info.modifiedAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? CanopyColors.glowColor.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename") {
                editedName = info.name
                isRenaming = true
            }
            Button("Duplicate") { onDuplicate() }
            Button("Show in Finder") { onShowInFinder() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
