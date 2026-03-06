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

    private var accentColor: Color {
        guard let nodeID = projectState.selectedNodeID,
              let treeID = projectState.selectedTreeID,
              let tree = projectState.project.trees.first(where: { $0.id == treeID }) else {
            return CanopyColors.nodeSeed
        }
        return SeedColor.colorForNode(nodeID, in: tree)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Unified top bar
            topBar
                .background(CanopyColors.bloomPanelBackground.opacity(0.95))

            Rectangle()
                .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                .frame(height: 1)

            // Content area
            Group {
                switch activePanel {
                case .synth:
                    FocusEngineView(projectState: projectState)
                case .sequencer:
                    FocusSequencerView(
                        projectState: projectState,
                        transportState: transportState,
                        accentColor: accentColor,
                        sequencerHasSelection: $sequencerHasSelection
                    )
                case .input:
                    FocusKeyboardView(projectState: projectState, transportState: transportState)
                }
            }
            .environment(\.canvasScale, 1.0)
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            .id(activePanel)
        }
        .background(CanopyColors.canvasBackground.ignoresSafeArea())
        .onAppear {
            activePanel = .sequencer
            installFocusKeyMonitor()
        }
        .onDisappear {
            removeFocusKeyMonitor()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Left side: panel-specific content
            HStack(spacing: 6) {
                if activePanel == .sequencer {
                    ModuleSwapButton(
                        options: [("Pitched", SequencerType.pitched), ("Drum", SequencerType.drum), ("Orbit", SequencerType.orbit), ("Spore", SequencerType.sporeSeq)],
                        current: projectState.selectedNode?.sequencerType ?? .pitched,
                        onChange: { type in
                            guard let nodeID = projectState.selectedNodeID else { return }
                            projectState.swapSequencer(nodeID: nodeID, to: type)
                        }
                    )
                    Text("SEQUENCE")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                } else {
                    Text(panelLabel(activePanel))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
            }

            Spacer()

            // Right side: tab pills + dice + expand
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(BloomPanel.allCases, id: \.self) { panel in
                        let isActive = activePanel == panel
                        Text(panelLabel(panel))
                            .font(.system(size: 11, weight: isActive ? .bold : .regular, design: .monospaced))
                            .foregroundColor(isActive ? CanopyColors.chromeTextBright : CanopyColors.chromeText.opacity(0.5))
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    activePanel = panel
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(CanopyColors.bloomPanelBackground.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
                )

                Button(action: {
                    guard let nodeID = projectState.selectedNodeID else { return }
                    SequencerActions.randomFill(projectState: projectState, nodeID: nodeID)
                }) {
                    Image(systemName: "dice")
                        .font(.system(size: 12))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Random scale fill")

                Button(action: {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        viewModeManager.exitFocus()
                    }
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Exit focus mode")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
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
