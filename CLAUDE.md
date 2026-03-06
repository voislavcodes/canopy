# CLAUDE.md — Canopy

> **"Where music grows."**
> A procedural DAW where music emerges from Node Trees, not timelines.

---

## Project Context

This is a Swift/SwiftUI audio DSP project (macOS). The codebase uses ASCII art canvas-based UI components, bloom panel layouts, and a sequencer architecture with Forest and Focus views. Always ensure builds succeed before committing.

---

## Planning & Exploration

When writing design docs or plans, use the user's provided content verbatim - do not condense, summarize, or rewrite unless explicitly asked. When the plan is ready, present it and wait for approval before exiting plan mode.

---

## What is Canopy?

Canopy is a macOS-native music creation tool that replaces the traditional DAW timeline with **Node Trees** — branching structures where each branch is a musical layer that plays simultaneously. Different branch lengths create natural polyrhythm. Songs progress by traversing a sequence of trees using configurable playback modes (depth-first, breadth-first, random, manual).

The user starts with a **seed** (a single node), grows branches (layers), shapes sounds, and builds a track tree by tree. The interface adapts to what's focused — selecting a node "blooms" contextual UI around it (synth controls, sequencer). The complexity grows organically with the user's creation.

---

## Core Philosophy — Non-Negotiable

These principles govern every decision. If an implementation conflicts with any of these, stop and rethink.

### 1. Seed → Tree → Track
Every session starts with a single node. The interface reveals itself progressively as the user builds. Never present complexity the user hasn't earned yet.

### 2. Physics, Not Dice
Polyrhythm is an emergent consequence of different branch lengths and step rates, not a configured feature. Transitions quantize to cycle boundaries by default. Emergence over prescription. Don't hardcode musical outcomes — create conditions for them to arise.

### 3. The Tree IS the Constraint
Every node must grow from an existing node. No orphans. No infinite artboard. The tree structure provides organization, not the user's spatial discipline. The canvas is bounded by tree extent.

### 4. No Band-Aids
If something doesn't fit the architecture, redesign. Don't hack around problems. Don't add flags to suppress symptoms. Fix root causes. This applies to code, audio, UI, and data model decisions equally.

### 5. Two Entry Points, One Destination
Users create music by: playing a keyboard or clicking a step sequencer. Both write to the same `NoteSequence` data. The node doesn't care how notes got there. Both entry points are first-class citizens.

---

## Tech Stack

- **Language**: Swift 5.8+
- **UI**: SwiftUI (AppKit interop via NSHostingView for window management)
- **Audio**: Pure AVAudioEngine — no AudioKit, no external audio dependencies
  - `AVAudioSourceNode` for custom oscillator/synth engine callbacks
  - All effects are custom DSP (no built-in AVAudioUnit effects used)
  - `AVAudioMixerNode` for per-node volume/pan
- **Build**: Swift Package Manager (SPM), no Xcode project
- **Platform**: macOS 13+ (Ventura)
- **Persistence**: `.canopy` JSON files via Codable

---

## Build & Run

Build and run through **Xcode**. The project can also be built from CLI:

```bash
xcodebuild -scheme Canopy build       # Compile
xcodebuild -scheme Canopy test        # Run tests
```

Open `Package.swift` in Xcode and it will generate the scheme automatically.

---

## Project Structure

```
Sources/Canopy/
├── main.swift                        # App entry point
├── App/                              # AppDelegate, CanopyWindow
├── Models/                           # Data model (see below)
├── State/                            # ObservableObject state management
├── Views/
│   ├── Forest/                       # Multi-tree canvas view
│   ├── Focus/                        # Full-screen single-node editor
│   ├── Meadow/                       # Mixer view (channel strips, metering)
│   ├── Canvas/                       # Bounded pan/zoom canvas
│   ├── Node/                         # Node rendering, presets
│   ├── Bloom/                        # Contextual synth panels around focused nodes
│   ├── Sequencer/                    # Step sequencer grid
│   ├── Keyboard/                     # Piano keyboard bar
│   ├── Chrome/                       # Toolbar, transport, effect boxes, bottom lane
│   └── Browser/                      # Project browser
├── Audio/                            # Synth engines, sequencers, DSP
│   └── Effects/                      # Custom effect implementations
├── Services/                         # File I/O, project factory, scale resolver, Euclidean rhythm
└── Theme/                            # Colors, constants, canvas scale environment
Tests/CanopyTests/
```

---

## The Sacred Data Model

The data model is the **single most important architectural element** — it's the contract between UI and audio engine. Do not modify these core structures without explicit approval.

### Hierarchy

```
CanopyProject
├── globalKey, bpm, scaleAwareEnabled
├── lfos: [LFODefinition], modulationRoutings: [ModulationRouting]
├── masterBus: MasterBus (global FX chain + Shore limiter)
├── trees: [NodeTree]
│   ├── rootNode: Node (the seed)
│   │   ├── sequence: NoteSequence (notes + arp/euclidean/mutation/direction configs)
│   │   ├── patch: SoundPatch (SoundType tagged enum — engine-specific config)
│   │   ├── effects: [Effect], stepRate: StepRate
│   │   └── children: [Node] (branches — recursive)
│   ├── transition: TransitionBehavior
│   └── sourceTreeID/variationType (variation lineage)
└── arrangements: [Arrangement] (treeIDs + traversalMode + looping)
```

### Key Invariants

- Every `NodeTree` has exactly one root `Node`
- Every `Node` must have a parent (except root)
- `StepRate` per node determines grid resolution — different rates across siblings create polyrhythm
- All model types conform to `Codable`, `Equatable`, and `Identifiable`
- Backward-compatible decoding via `decodeIfPresent` for all fields added after v1

---

## Synth Engines

Each engine has a `*Voice.swift` (DSP) and `*VoiceManager.swift` (polyphony/voice allocation), selected via `SoundType` tagged enum:

**Pitched**: Oscillator (basic waveforms), Schmynth (circuit-modeled subtractive), WestCoast (FM/wavefolder/LPG), Flow (64-partial additive + fluid dynamics), Tide (16-band spectral sequencer), Swarm (64-oscillator autonomous agents), Spore (stochastic granular), Fuse (virtual analog circuit)

**Drums**: DrumKit (FM, 8 voices), Quake (gravitational/orbital coupling), Volt (analog circuit, resonant kick)

Placeholder configs exist for Sampler and AUv3 (not yet implemented).

---

## Effects

All effects are custom DSP in `Audio/Effects/`. No built-in AVAudioUnit effects. Each is an `EffectSlot` tagged enum case — no protocol existentials on the audio thread.

**Mono**: Color (Moog filter), Heat (distortion), Echo (delay), Space (Freeverb), Pressure (compressor), Drift (traveling delay), Tide (phaser), Terrain (EQ), Level (gain staging)

**True stereo**: Ghost (living decay), Nebula (evolving FDN reverb), Melt (spectral gravity)

**Shore**: Master bus brick-wall limiter (separate from per-node effects). Legacy effect types map to canonical names via `EffectType.canonical`.

---

## Audio Architecture

### Signal Path

```
AVAudioSourceNode (synth engine) → EffectChain (per-node) → AVAudioMixerNode (volume/pan) → Master Mixer → MasterBus (Shore limiter) → Output
```

Each `NodeTree` maps to a `TreeAudioGraph` containing one `NodeAudioUnit` per node. The `AudioEngine` coordinates all graphs. `ForestTimeline` handles multi-tree playback with sample-precise crossfade transitions.

### Key Audio Components

- **NodeAudioUnit**: Per-node wrapper — owns voice manager + effect chain
- **TreeAudioGraph**: Builds/tears down audio subgraphs per tree
- **MasterBusAU**: Global effects chain + Shore limiter
- **ForestTimeline**: Multi-tree timeline with crossfade transitions
- **EffectChain + EffectSlot**: Tagged enum effect routing (no heap allocation per sample)

### Sequencers

- **Sequencer**: Generic note event scheduler, reads NoteSequence
- **OrbitSequencer**: Gravitational rhythm — bodies orbit zones, collisions trigger hits (control-rate physics)
- **SporeSequencer**: Probabilistic sequencer with autocorrelation, random walks, Poisson clocking
- **ArpNotePool**: Arpeggiator voice pool
- **SequenceTransforms**: Runtime transforms on NoteSequence (transpose, invert, rotate, etc.)

### Audio Thread Rules

Oscillator/synth render callbacks must be lock-free. No allocations, no Swift reference counting, no Objective-C messaging in the render callback. All buffers pre-allocated via `UnsafeMutablePointer<Float>`.

---

## State Management

| State Object | Purpose |
|---|---|
| **ProjectState** | Musical state — project data, selected node, MIDI capture, keyboard state, LFOs, modulation. Changes on user edits. |
| **CanvasState** | Visual transform — scale, offset, gesture accumulators. Changes at 60fps during gestures. |
| **TransportState** | Playback control, BPM management |
| **BloomState** | Panel offset tracking for draggable bloom panels |
| **ViewModeManager** | Forest/Focus/Meadow mode switching |
| **ForestPlaybackState** | Forest-level timeline playback (tree sequencing, transitions) |
| **MIDICaptureBuffer** | Circular buffer for keyboard/MIDI input capture |

`ProjectState` and `CanvasState` are deliberately separated — canvas transforms should never trigger project re-renders.

---

## UI Patterns

### Three View Modes

- **Forest** — Multi-tree canvas. Shows all trees, node hierarchies, branching. The primary composition view.
- **Focus** — Full-screen single-node editor. Enter via Enter key, exit via Esc. Shows enlarged sequencer grid and engine controls.
- **Meadow** — Mixer view. Channel strips per branch with volume, pan, metering, solo/mute. Master bus fader.

Switched via `ViewModeManager` and toolbar tabs.

### Bloom UI

Selecting a node causes **Bloom panels** to appear around it — contextual synth controls specific to the node's engine type. Each engine has its own panel (SchmynthPanel, FlowPanel, TidePanel, etc.). Bloom panels are draggable via `BloomDragHandle`. Clicking empty canvas dismisses the bloom.

### ASCII Art UI

Many controls use ASCII art rendered via SwiftUI `Canvas` + `TimelineView`:
- **Synth panels**: Circuit schematics using Unicode box-drawing characters (FusePanel, TidePanel)
- **Knobs**: Interactive draggable ASCII art controls (FlowPanel CURR/VISC/DENS)
- **Sequencer grid**: ASCII block lanes with dot notation
- **Wobble strips**: Canvas-drawn interactive knobs with wave indicators

Grid system: `fontSize * 0.62` cellW, `fontSize * 1.35` rowH. Parameters drive character selection, opacity, and position.

### Constrained Canvas

The canvas supports pan and zoom but is **bounded** by the tree's extent plus padding. It is NOT an infinite artboard. Zoom range: 0.3x–3.0x.

---

## UI Implementation

When implementing UI changes, match existing patterns in the codebase exactly. Before proposing a new approach, check how similar controls (wobble strips, bloom panels, knob controls) are already implemented and follow that pattern.

---

## Audio/DSP Guidelines

For audio/DSP bugs: prefer Double precision over Float32 for signal processing math. Check for aliasing artifacts, ADAA cancellation, and residual energy in FX chains. Don't use Thread.sleep for audio timing - use buffer-level fades. Consult `.claude/projects/-Users-void-Documents-canopy/memory/dsp-lessons.md` for hard-won anti-patterns before writing or modifying audio code.

---

## Code Standards

### General
- Swift conventions: camelCase properties, PascalCase types
- Prefer value types (structs, enums) over classes except for ObservableObject
- All public interfaces need documentation comments
- No force unwraps (`!`) except in tests — use guard/if-let
- No `print()` for debugging — use `os.Logger` with subsystem "com.canopy"

### Naming
- Files named after the primary type they contain
- Views suffixed with `View` (e.g., `NodeView`, `CanopyCanvasView`)
- State objects suffixed with `State` (e.g., `ProjectState`)
- Services suffixed with `Service` (e.g., `ProjectFileService`)
- Synth engines: `*Voice.swift` (DSP) + `*VoiceManager.swift` (polyphony)
- Bloom panels: `*Panel.swift` (e.g., `SchmynthPanel`, `FlowPanel`)

### Architecture
- Models are pure data (no business logic, no UI imports)
- State objects own the business logic
- Views are thin — they read state and dispatch actions
- Audio code never imports SwiftUI; UI code never imports AVFoundation
- Services are stateless with static methods where possible
- Effects use tagged enum `EffectSlot` — no protocol existentials on audio thread

### App Lifecycle
Uses `main.swift` with `NSApplication` bootstrap and `AppDelegate`. Window management via `CanopyWindow`.

### Testing
- All model types must have Codable round-trip tests
- Audio engine integration tests verify node → sound mapping
- Test file naming: `[Feature]Tests.swift`

---

## Current Status

All core synthesis, effects, sequencing, and view infrastructure is built and working. The next milestone is **River** — Canopy's timeline editor.

---

## Common Pitfalls to Avoid

- **Don't make the canvas infinite.** The tree bounds the viewport. This is deliberate.
- **Don't separate instrument from pattern.** A node IS its sound + its sequence. They're inseparable.
- **Don't add features to fix architecture problems.** If the data model doesn't support something, evolve the model. Don't bolt workarounds on top.
- **Don't block the audio thread.** Render callbacks must be lock-free. No allocations, no Swift reference counting, no Objective-C messaging in the render callback.
- **Don't over-abstract early.** Build concrete implementations first. Extract protocols when you see a real need, not a hypothetical one.
- **Don't fight SwiftUI.** If something is painful in SwiftUI, consider whether AppKit interop is the right call. The canvas and audio visualizations may need it.
- **Don't use AVAudioUnit built-in effects.** All effects are custom DSP via EffectSlot. Keep it that way.

---

*Canopy — where music grows.*
