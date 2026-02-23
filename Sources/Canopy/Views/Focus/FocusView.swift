import SwiftUI
import AppKit

/// Parent coordinator for Focus mode — shows ONE module at a time filling the entire
/// content area. Arrow keys cycle between modules (engine, sequencer, keyboard).
struct FocusView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @EnvironmentObject var viewModeManager: ViewModeManager

    /// Which panel is currently displayed. Defaults to sequencer on enter.
    @State private var activePanel: BloomPanel = .sequencer
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            CanopyColors.canvasBackground
                .ignoresSafeArea()

            Group {
                switch activePanel {
                case .synth:
                    FocusEngineView(projectState: projectState)
                case .sequencer:
                    FocusSequencerView(projectState: projectState, transportState: transportState)
                case .input:
                    FocusKeyboardView(projectState: projectState, transportState: transportState)
                }
            }
            .environment(\.canvasScale, 1.0)
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            .id(activePanel)

            // Panel indicator
            VStack {
                panelIndicator
                Spacer()
            }
        }
        .onAppear {
            activePanel = .sequencer
            installFocusKeyMonitor()
        }
        .onDisappear {
            removeFocusKeyMonitor()
        }
    }

    // MARK: - Panel Indicator

    private var panelIndicator: some View {
        HStack(spacing: 12) {
            ForEach(BloomPanel.allCases, id: \.self) { panel in
                Text(panelLabel(panel))
                    .font(.system(size: 11, weight: activePanel == panel ? .bold : .regular, design: .monospaced))
                    .foregroundColor(activePanel == panel ? CanopyColors.chromeTextBright : CanopyColors.chromeText.opacity(0.5))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            activePanel = panel
                        }
                    }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(CanopyColors.bloomPanelBackground.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
        )
        .padding(.top, 8)
    }

    private func panelLabel(_ panel: BloomPanel) -> String {
        switch panel {
        case .synth: return "ENGINE"
        case .sequencer: return "SEQUENCER"
        case .input: return "INPUT"
        }
    }

    // MARK: - Keyboard Navigation

    private func cyclePanels(direction: Int) {
        let panels = BloomPanel.allCases
        guard let idx = panels.firstIndex(of: activePanel) else { return }
        let next = (idx + direction + panels.count) % panels.count
        withAnimation(.easeInOut(duration: 0.15)) {
            activePanel = panels[next]
        }
    }

    private func installFocusKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModeManager] event in
            guard let viewModeManager = viewModeManager else { return event }
            guard !viewModeManager.isForest else { return event }

            switch event.keyCode {
            case 53: // Esc — exit focus mode
                DispatchQueue.main.async {
                    withAnimation(.spring(duration: 0.3)) {
                        viewModeManager.exitFocus()
                    }
                }
                return nil
            case 123: // Left arrow — previous panel
                DispatchQueue.main.async { [self] in
                    self.cyclePanels(direction: -1)
                }
                return nil
            case 124: // Right arrow — next panel
                DispatchQueue.main.async { [self] in
                    self.cyclePanels(direction: 1)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeFocusKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
