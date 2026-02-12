# CLAUDE.md — Canopy

> **"Where music grows."**
> A procedural DAW where music emerges from Node Trees, not timelines.

---

## What is Canopy?

Canopy is a macOS-native music creation tool that replaces the traditional DAW timeline with **Node Trees** — branching structures where each branch is a musical layer that plays simultaneously. Different branch lengths create natural polyrhythm. Songs progress by traversing a sequence of trees using configurable playback modes (sequential, ping-pong, Brownian, random).

The user starts with a **seed** (a single node), grows branches (layers), shapes sounds, and builds a track tree by tree. The interface adapts to what's focused — selecting a node "blooms" contextual UI around it (synth controls, sequencer, Claude prompt). The complexity grows organically with the user's creation.

---

## Core Philosophy — Non-Negotiable

These principles govern every decision. If an implementation conflicts with any of these, stop and rethink.

### 1. Seed → Tree → Track
Every session starts with a single node. The interface reveals itself progressively as the user builds. Never present complexity the user hasn't earned yet.

### 2. Physics, Not Dice
Polyrhythm is an emergent consequence of different branch lengths, not a configured feature. Transitions quantize to cycle boundaries (LCM of branch lengths) by default. Emergence over prescription. Don't hardcode musical outcomes — create conditions for them to arise.

### 3. The Tree IS the Constraint
Every node must grow from an existing node. No orphans. No infinite artboard. The tree structure provides organization, not the user's spatial discipline. The canvas is bounded by tree extent.

### 4. No Band-Aids
If something doesn't fit the architecture, redesign. Don't hack around problems. Don't add flags to suppress symptoms. Fix root causes. This applies to code, audio, UI, and data model decisions equally.

### 5. Three Entry Points, One Destination
Users create music by: playing a keyboard, clicking a step sequencer, or describing to Claude. All three write to the same `NoteSequence` data. The node doesn't care how notes got there. All entry points are first-class citizens.

### 6. Claude as Gardener
AI assists at every level — within a node ("make this darker"), within a tree ("add a bass branch"), across trees ("evolve this for more energy"). Claude generates structured data (JSON → NoteSequence), never audio directly.

---

## Tech Stack

- **Language**: Swift 5.8+
- **UI**: SwiftUI (AppKit interop via NSHostingView for window management)
- **Audio**: Pure AVAudioEngine — no AudioKit, no external audio dependencies
  - `AVAudioSourceNode` for custom oscillator callbacks
  - Built-in `AVAudioUnitReverb`, `AVAudioUnitDelay`, `AVAudioUnitEQ`, `AVAudioUnitDistortion` for effects
  - `AVAudioMixerNode` for per-node volume/pan
  - AUv3 hosting via `AVAudioUnit.instantiate(with:)` in future phases
- **AI**: Claude API (Haiku 4.5 default, Sonnet for complex compositional tasks)
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

If using SPM structure, open `Package.swift` in Xcode and it will generate the scheme automatically. If using an `.xcodeproj`, use the standard Xcode build/run workflow (⌘R).

---

## Project Structure

```
Sources/Canopy/
├── main.swift / CanopyApp.swift       # App entry point (@main App lifecycle)
├── App/                              # App entry, window config, root SwiftUI view
├── Models/                           # Sacred data model (see below)
├── State/                            # ObservableObject state management
├── Views/
│   ├── Canvas/                       # Bounded pan/zoom canvas
│   ├── Node/                         # Node rendering + glow effects
│   ├── Bloom/                        # Contextual UI that appears around focused nodes
│   ├── Sequencer/                    # Step sequencer grid
│   ├── Keyboard/                     # On-screen keyboard
│   └── Chrome/                       # Toolbar, transport, arrangement
├── Audio/                            # AVAudioEngine wrappers + oscillators
├── Generation/                       # Claude API integration + prompt building
├── Services/                         # File I/O, project factory
└── Theme/                            # Colors, constants, design tokens
Tests/CanopyTests/
```

---

## The Sacred Data Model

The data model is the **single most important architectural element** — it's the contract between UI, audio engine, and Claude. Do not modify these core structures without explicit approval.

### Hierarchy

```
CanopyProject
├── trees: [NodeTree]
│   └── rootNode: Node (the seed)
│       ├── sequence: NoteSequence (the musical content)
│       │   └── events: [NoteEvent] (pitch, velocity, start, duration)
│       ├── sound: SoundPatch (the instrument)
│       ├── effects: [Effect] (the signal chain)
│       └── children: [Node] (branches — recursive)
└── arrangement: Arrangement
    ├── treeOrder: [UUID]
    └── traversalMode: TraversalMode
```

### Key Invariants

- Every `NodeTree` has exactly one root `Node`
- Every `Node` must have a parent (except root)
- `Node.lengthInBeats` determines loop length — different values across siblings create polyrhythm
- `NoteSequence.lengthInBeats` must match its parent `Node.lengthInBeats`
- The tree's natural cycle = LCM of all branch `lengthInBeats` values
- All model types conform to `Codable`, `Equatable`, and `Identifiable`

---

## Audio Architecture

### Pure AVAudioEngine — No External Dependencies

The audio engine is built entirely on Apple's `AVAudioEngine`. Every node in a `NodeTree` maps to an audio subgraph:

```
AVAudioSourceNode (oscillator) → [AVAudioUnitEffect chain] → AVAudioMixerNode (per-node level/pan) → Main Mixer → Output
```

### Oscillator Implementation

Custom oscillators via `AVAudioSourceNode` render callback. The math is straightforward:
- **Sine**: `sin(2π × frequency × phase)`
- **Saw**: `2 × (phase mod 1) - 1`
- **Square**: `phase mod 1 < 0.5 ? 1 : -1`
- **Triangle**: `4 × abs(phase mod 1 - 0.5) - 1`

Phase is accumulated per-sample: `phase += frequency / sampleRate`

### Sequencer

A timing engine reads `NoteSequence.events` and triggers oscillator frequency/gate changes at the correct beat positions. Uses `AVAudioEngine.outputNode.installTap` or a `DispatchSourceTimer` synced to BPM for timing.

### Simultaneous Playback

All branches in a tree play simultaneously. Each branch's sequence loops independently at its own `lengthInBeats`. The audio engine doesn't know about polyrhythm — it just plays each branch in its own loop. Polyrhythm is emergent.

---

## State Management

Two separate `ObservableObject` instances:

- **`ProjectState`**: The musical state — project data, selected node ID, dirty flag. Changes on user edits.
- **`CanvasState`**: Visual transform — scale, offset, gesture accumulators. Changes at 60fps during gestures.

These are separated because canvas transforms should never trigger project re-renders. This is a deliberate performance decision.

---

## UI Patterns

### Focus Model (Not Modal)

The UI never has "enter/exit" states. Selecting a node doesn't navigate to a different screen — it causes the **Bloom UI** to appear around the focused node:

- **Left**: Sound/synth controls
- **Right**: Step sequencer
- **Below**: Claude prompt input
- **Bottom (persistent)**: Keyboard — always plays into the focused node

Clicking empty canvas dismisses the bloom. Clicking a different node transfers the bloom. The transition should be smooth and animated.

### Constrained Canvas

The canvas supports pan and zoom but is **bounded** by the tree's extent plus padding. It is NOT an infinite artboard. The tree dictates the viewport scale. Small tree = intimate view. Large tree = zoomed out. Zoom range: 0.3x–3.0x.

---

## Claude Generation Contract

When requesting AI generation, serialize a `GenerationContext` to JSON and include it in the prompt. Parse the response as a `GenerationResult`.

Claude generates **structured musical data** (note events, patch suggestions), never audio. The app is responsible for turning that data into sound.

Haiku 4.5 handles fast structured generation (variations, sequences). Sonnet handles complex compositional requests (reharmonization, style-aware generation). The model should be selectable per request, abstracted behind a protocol.

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

### Architecture
- Models are pure data (no business logic, no UI imports)
- State objects own the business logic
- Views are thin — they read state and dispatch actions
- Audio code never imports SwiftUI; UI code never imports AVFoundation
- Services are stateless with static methods where possible

### App Lifecycle
With Xcode available, use the standard `@main struct CanopyApp: App` lifecycle. Manual `NSApplication` bootstrap is not needed. Use `NSApplicationDelegateAdaptor` if AppKit-level control is required (e.g., custom menu bar, window configuration).

### Testing
- All model types must have Codable round-trip tests
- Audio engine integration tests verify node → sound mapping
- Test file naming: `[Feature]Tests.swift`

---

## Phased Build Plan

The project is built in 8 phases. Work sequentially — each phase builds on the previous. Do not skip ahead.

1. **The Silent Seed** — App shell, data model, canvas, seed node rendering ✅
2. **Give the Seed a Voice** — AVAudioEngine oscillators, keyboard, step sequencer, playback
3. **Grow the Tree** — Branching, multi-node simultaneous playback, polyrhythm
4. **Shape the Sound** — Effects chain, ADSR envelopes, richer synthesis
5. **Claude as Gardener** — AI generation at node, tree, and arrangement level
6. **Forest** — Multiple trees, arrangement view, transitions, export
7. **Traversal Modes** — Sequential, ping-pong, Brownian, random, custom, capture
8. **Polish & Ship** — Animations, onboarding, performance, App Store

Each phase has a clear deliverable. Verify it works before moving on.

---

## Common Pitfalls to Avoid

- **Don't make the canvas infinite.** The tree bounds the viewport. This is deliberate.
- **Don't separate instrument from pattern.** A node IS its sound + its sequence. They're inseparable.
- **Don't add features to fix architecture problems.** If the data model doesn't support something, evolve the model. Don't bolt workarounds on top.
- **Don't block the audio thread.** Oscillator render callbacks must be lock-free. No allocations, no Swift reference counting, no Objective-C messaging in the render callback.
- **Don't over-abstract early.** Build concrete implementations first. Extract protocols when you see a real need, not a hypothetical one.
- **Don't fight SwiftUI.** If something is painful in SwiftUI, consider whether AppKit interop is the right call. The canvas and audio visualizations may need it.

---

*Canopy — where music grows.*
