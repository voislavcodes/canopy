import SwiftUI
import AppKit

// MARK: - Focus Selection Notifications

extension Notification.Name {
    static let focusClearSelection = Notification.Name("focusClearSelection")
    static let focusTransposeUp = Notification.Name("focusTransposeUp")
    static let focusTransposeDown = Notification.Name("focusTransposeDown")
    static let focusMoveLeft = Notification.Name("focusMoveLeft")
    static let focusMoveRight = Notification.Name("focusMoveRight")
    static let focusDeleteSelection = Notification.Name("focusDeleteSelection")
    static let focusCopySelection = Notification.Name("focusCopySelection")
    static let focusPasteSelection = Notification.Name("focusPasteSelection")
    static let focusDuplicateSelection = Notification.Name("focusDuplicateSelection")
}

/// Parent coordinator for Focus mode — shows ONE module at a time filling the entire
/// content area. Arrow keys cycle between modules (engine, sequencer, keyboard).
struct FocusView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @EnvironmentObject var viewModeManager: ViewModeManager

    /// Which panel is currently displayed. Defaults to sequencer on enter.
    @State private var activePanel: BloomPanel = .sequencer
    @State private var keyMonitor: Any?
    /// Whether the sequencer has an active note selection (for key event routing).
    @State private var sequencerHasSelection: Bool = false

    var body: some View {
        ZStack {
            CanopyColors.canvasBackground
                .ignoresSafeArea()

            Group {
                switch activePanel {
                case .synth:
                    FocusEngineView(projectState: projectState)
                case .sequencer:
                    FocusSequencerView(
                        projectState: projectState,
                        transportState: transportState,
                        sequencerHasSelection: $sequencerHasSelection
                    )
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
            case 53: // Esc
                DispatchQueue.main.async { [self] in
                    // First Esc: deselect notes if selection active
                    if self.sequencerHasSelection, self.activePanel == .sequencer {
                        self.sequencerHasSelection = false
                        // Post notification for sequencer to clear selection
                        NotificationCenter.default.post(name: .focusClearSelection, object: nil)
                    } else {
                        // Second Esc (or no selection): exit focus mode
                        withAnimation(.spring(duration: 0.3)) {
                            viewModeManager.exitFocus()
                        }
                    }
                }
                return nil
            case 126: // Up arrow — transpose up if selection active on sequencer
                if self.sequencerHasSelection && self.activePanel == .sequencer {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .focusTransposeUp, object: nil)
                    }
                    return nil
                }
                return event
            case 125: // Down arrow — transpose down if selection active on sequencer
                if self.sequencerHasSelection && self.activePanel == .sequencer {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .focusTransposeDown, object: nil)
                    }
                    return nil
                }
                return event
            case 123: // Left arrow
                if self.sequencerHasSelection && self.activePanel == .sequencer {
                    // Move selection earlier
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .focusMoveLeft, object: nil)
                    }
                    return nil
                }
                DispatchQueue.main.async { [self] in
                    self.cyclePanels(direction: -1)
                }
                return nil
            case 124: // Right arrow
                if self.sequencerHasSelection && self.activePanel == .sequencer {
                    // Move selection later
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .focusMoveRight, object: nil)
                    }
                    return nil
                }
                DispatchQueue.main.async { [self] in
                    self.cyclePanels(direction: 1)
                }
                return nil
            case 51: // Delete / Backspace
                if self.sequencerHasSelection && self.activePanel == .sequencer {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .focusDeleteSelection, object: nil)
                    }
                    return nil
                }
                return event
            default:
                // Cmd+C, Cmd+V, Cmd+D
                if event.modifierFlags.contains(.command) {
                    if self.sequencerHasSelection && self.activePanel == .sequencer {
                        switch event.charactersIgnoringModifiers {
                        case "c":
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .focusCopySelection, object: nil)
                            }
                            return nil
                        case "v":
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .focusPasteSelection, object: nil)
                            }
                            return nil
                        case "d":
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .focusDuplicateSelection, object: nil)
                            }
                            return nil
                        default:
                            break
                        }
                    } else if event.charactersIgnoringModifiers == "v" && self.activePanel == .sequencer {
                        // Cmd+V without selection: paste at position 0
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .focusPasteSelection, object: nil)
                        }
                        return nil
                    }
                }
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
