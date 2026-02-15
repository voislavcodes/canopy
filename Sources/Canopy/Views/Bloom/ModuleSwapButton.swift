import SwiftUI

/// Small swap icon button for panel headers.
/// Tap to show a popover with module type radio options.
struct ModuleSwapButton<Option: Hashable>: View {
    let options: [(label: String, value: Option)]
    let current: Option
    let onChange: (Option) -> Void

    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(CanopyColors.chromeBackground.opacity(0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(options.indices, id: \.self) { i in
                    let opt = options[i]
                    Button(action: {
                        onChange(opt.value)
                        showPopover = false
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: current == opt.value ? "circle.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundColor(current == opt.value ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                            Text(opt.label)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(current == opt.value ? CanopyColors.chromeTextBright : CanopyColors.chromeText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(CanopyColors.bloomPanelBackground)
        }
    }
}
