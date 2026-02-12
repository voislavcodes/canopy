# Canopy — Build Plan

> **"Where music grows."**
> A procedural DAW where music emerges from Node Trees, not timelines.

---

## Product Philosophy

Canopy is an emergent music creation tool. Instead of the traditional DAW paradigm of tracks and timelines, Canopy uses **Node Trees** — living, branching structures where each branch is a musical layer that plays simultaneously. Different branch lengths create natural polyrhythm. The song progresses by traversing a sequence of trees using configurable playback modes.

### Core Principles

- **Seed → Tree → Track**: Every session starts with a single node. Complexity grows organically.
- **Progressive Disclosure**: The interface reveals itself as the user builds. Empty canvas → seed → blooming UI around the focused node → tree → arrangement.
- **Three Entry Points, One Destination**: Users create music by playing on a keyboard, clicking a step sequencer, or describing to Claude. All three write to the same node sequence data.
- **Physics, Not Dice**: Polyrhythm is a natural consequence of different branch lengths, not a configured feature. Transitions quantize to cycle boundaries by default. Emergence over prescription.
- **The Tree IS the Constraint**: No infinite artboard. Every node must grow from an existing node. The tree provides structure, not the user's spatial discipline.
- **Claude as Gardener**: AI assists at every level — within a node ("make this sound darker"), within a tree ("add a bass branch"), across trees ("evolve this into something with more energy").

---

## Architecture Overview

### Platform & Stack

- **Platform**: macOS native app
- **Language**: Swift
- **UI Framework**: SwiftUI (AppKit interop for custom audio views)
- **Audio Engine**: AVAudioEngine + AudioKit
- **Plugin Format**: AUv3 only (native to AVAudioEngine, no bridging needed). VST3/CLAP deferred.
- **AI Generation**: Claude API (Haiku 4.5 for fast structured generation, Sonnet for complex compositional tasks)
- **Data Persistence**: Local project files (JSON-based, `.canopy` extension)

### Layer Architecture

```
┌─────────────────────────────────────────┐
│  UI Layer (SwiftUI)                     │
│  Canvas, Node Editor, Bloom UI,         │
│  Arrangement View, Keyboard             │
├─────────────────────────────────────────┤
│  Model Layer (Swift)                    │
│  NodeTree, Branch, Node, Sequence,      │
│  Arrangement, TraversalEngine           │
├─────────────────────────────────────────┤
│  Audio Engine Layer (AudioKit)          │
│  Synth Nodes, Effects, Mixer,           │
│  Sequencer, AUv3 Host                   │
├─────────────────────────────────────────┤
│  Generation Layer (Claude API)          │
│  Prompt Builder, Response Parser,       │
│  Musical Context Extractor              │
└─────────────────────────────────────────┘
```

---

## Data Model

This is Canopy's most critical architectural decision — the contract between UI, audio engine, and Claude.

### Project

```swift
struct CanopyProject {
    let id: UUID
    var name: String
    var bpm: Double                    // Global tempo
    var trees: [NodeTree]              // All trees in the project
    var arrangement: Arrangement       // How trees are ordered/traversed
    var createdAt: Date
    var updatedAt: Date
}
```

### NodeTree

The fundamental unit — a living musical moment.

```swift
struct NodeTree {
    let id: UUID
    var name: String
    var rootNode: Node                 // The seed — every tree has exactly one root
    var transitionBehavior: TransitionBehavior
}

struct TransitionBehavior {
    var mode: TransitionMode            // .auto or .manual
    var manualCycleDuration: Int?       // In beats, if mode is .manual
    // .auto = wait for longest branch cycle (LCM of all branch lengths)
    // .manual = transition after N beats regardless of cycle completion
}

enum TransitionMode {
    case auto    // Transition when all branches resolve (LCM)
    case manual  // Transition after specified beat count
}
```

### Node

A single unit within a tree — either the root or a branch endpoint.

```swift
struct Node {
    let id: UUID
    var name: String
    var type: NodeType
    var sequence: NoteSequence         // The musical content
    var sound: SoundPatch              // The instrument/synth configuration
    var effects: [Effect]              // Effects chain
    var children: [Node]               // Child branches (recursive tree structure)
    var lengthInBeats: Int             // Loop length — different per branch = polyrhythm
    var level: Float                   // Volume 0.0–1.0
    var pan: Float                     // Stereo position -1.0 to 1.0
    
    /// Computed: distance from root (depth in tree)
    var depth: Int { /* computed by traversal */ }
}

enum NodeType {
    case root                          // The seed — one per tree
    case branch                        // A musical layer
}
```

### NoteSequence

The musical representation format — the universal data that all three input modes write to.

```swift
struct NoteSequence {
    var events: [NoteEvent]
    var lengthInBeats: Int             // Must match parent Node.lengthInBeats
    var key: MusicalKey?               // Optional: detected or user-set
    var scale: Scale?                  // Optional: detected or user-set
}

struct NoteEvent {
    var pitch: Int                     // MIDI note number (0-127)
    var velocity: Float                // 0.0–1.0
    var startBeat: Double              // Position in beats (e.g., 0.0, 0.5, 1.25)
    var durationBeats: Double          // Length in beats
}

struct MusicalKey {
    var root: PitchClass               // C, C#, D, etc.
    var mode: ScaleMode                // major, minor, dorian, etc.
}
```

### SoundPatch

The instrument configuration for a node.

```swift
struct SoundPatch {
    var type: SoundType
    var parameters: [String: Double]   // Flexible param storage
}

enum SoundType {
    case oscillator(OscillatorConfig)
    case sampler(SamplerConfig)
    case auv3(AUv3Config)              // External plugin — future
}

struct OscillatorConfig {
    var waveform: Waveform             // .sine, .saw, .square, .triangle
    var detune: Double                 // Cents
    var octave: Int
}
```

### Effects

```swift
struct Effect {
    let id: UUID
    var type: EffectType
    var parameters: [String: Double]
    var wet: Float                     // 0.0–1.0
    var bypassed: Bool
}

enum EffectType {
    case reverb
    case delay
    case filter
    case chorus
    case drive
    case phaser
    case flanger
    case compressor
}
```

### Arrangement & Traversal

```swift
struct Arrangement {
    var treeOrder: [UUID]              // Ordered list of NodeTree IDs
    var traversalMode: TraversalMode
}

enum TraversalMode {
    case sequential                    // 1 → 2 → 3 → 4 → 5
    case pingPong                      // 1 → 2 → 3 → 2 → 1 → 2 → ...
    case random                        // Any tree, any time
    case brownian                      // Random walk to adjacent trees
    case custom([Int])                 // User-defined order
}
```

### Claude Generation Format

When requesting generation from Claude, we send a `GenerationContext` and receive a `GenerationResult`. This is the contract between the app and the API.

```swift
// Sent to Claude (serialized as JSON in the prompt)
struct GenerationContext {
    var requestType: GenerationRequestType
    var musicalContext: MusicalContext
    var instruction: String            // User's natural language request
}

enum GenerationRequestType {
    case newSequence                   // "Give me a melody"
    case variation                     // "Vary this sequence"
    case newBranch                     // "Add a bass layer to this tree"
    case evolveTree                    // "Evolve this tree with more energy"
}

struct MusicalContext {
    var bpm: Double
    var key: MusicalKey?
    var scale: Scale?
    var existingSequences: [NoteSequence]  // Other branches for harmonic context
    var parentSequence: NoteSequence?      // The branch this grows from
    var lengthInBeats: Int
    var energyLevel: Double?               // 0.0–1.0, optional hint
}

// Received from Claude (parsed from JSON response)
struct GenerationResult {
    var sequence: NoteSequence
    var suggestedSound: SoundPatch?    // Optional: Claude can suggest a patch
    var suggestedEffects: [Effect]?    // Optional: Claude can suggest effects
}
```

---

## UI Architecture

### The Canvas

The main view is a **constrained, pannable/zoomable canvas** that shows the current Node Tree. It is NOT an infinite artboard — the viewport is bounded by the tree's extent plus comfortable padding.

### Focus Model

The UI follows a **focus-driven** paradigm — no modal enter/exit states:

1. **Nothing selected**: Canvas shows the tree structure. Minimal chrome.
2. **Node selected**: The **Bloom UI** appears around the focused node:
   - **Left**: Sound controls (synth parameters, waveform selector)
   - **Right**: Step sequencer grid
   - **Below**: Claude prompt input (contextual to selected node)
   - **Bottom persistent**: Keyboard (always plays into focused node)
3. **Effect selected within node**: Detail zone narrows to show effect parameters.
4. **Arrangement view**: Toggled or zoomed out — shows all trees in sequence with traversal controls.

### Bloom UI Concept

When a node is selected, the interface "blooms" around it like a flower opening:
- UI elements animate outward from the node
- The specific panels shown depend on the node's type and content
- Clicking away collapses the bloom smoothly
- Clicking a different node transitions the bloom to the new target

### Arrangement View

Shows all Node Trees in the project side-by-side. Each tree is a compact visual showing its branching structure. Traversal mode selector and transport controls live here. An **energy curve** is drawn behind the trees showing the density/energy arc of the track.

---

## Phased Build Plan

### Phase 1: Foundation — The Silent Seed

**Goal**: App shell, data model, single node on canvas.

- [ ] Create Xcode project (SwiftUI, macOS target)
- [ ] Implement core data models: `CanopyProject`, `NodeTree`, `Node`, `NoteSequence`, `NoteEvent`
- [ ] Create the canvas view with pan and zoom (bounded, not infinite)
- [ ] Render a single root node (the seed) centered on the canvas
- [ ] Implement node selection with visual feedback (glow ring)
- [ ] Project save/load as `.canopy` JSON files
- [ ] Basic app chrome: toolbar, project name, transport placeholder

**Deliverable**: App opens with a seed node on a dark canvas. You can click it. Nothing plays yet.

---

### Phase 2: Give the Seed a Voice

**Goal**: A single node makes sound.

- [ ] Integrate AudioKit into the project
- [ ] Implement `SoundPatch` → AudioKit oscillator node mapping
- [ ] Build basic synth controls in Bloom UI (left panel): waveform selector, detune, octave
- [ ] Implement on-screen keyboard (persistent bottom bar)
- [ ] Keyboard plays the selected node's oscillator in real-time
- [ ] Implement `NoteSequence` playback engine (loop a sequence of `NoteEvent`s)
- [ ] Build step sequencer in Bloom UI (right panel): grid of steps, click to toggle
- [ ] Step sequencer writes to `NoteSequence`, plays back in loop
- [ ] Transport controls: play/stop/BPM

**Deliverable**: Click the seed, choose a waveform, play the keyboard or click in a sequence, hear it loop. The seed has a voice.

---

### Phase 3: Grow the Tree

**Goal**: Branching works. Multiple nodes play simultaneously.

- [ ] Implement "Add Branch" interaction (+ button on selected node, or drag gesture)
- [ ] New branch nodes appear connected to parent with animated line
- [ ] Each node has independent `lengthInBeats` and its own `NoteSequence`
- [ ] Audio engine plays ALL branches simultaneously, each looping at its own length
- [ ] Implement polyrhythm: branches with different lengths cycle independently
- [ ] Display computed cycle length (LCM) on the tree
- [ ] Node-level mix controls: volume (level) and pan per node
- [ ] Audio mixer aggregates all nodes in the tree
- [ ] Bloom UI transfers to newly selected nodes smoothly
- [ ] Visual branch rendering: lines connecting nodes, color-coded by type

**Deliverable**: Build a tree with 3-4 branches, each a different length. Hear them polyrhythm together. The tree is alive.

---

### Phase 4: Shape the Sound

**Goal**: Effects chain and richer synthesis.

- [ ] Implement effects chain per node: reverb, delay, filter, drive, chorus
- [ ] Effects UI in Bloom panel (accessible when drilling into a node's effects)
- [ ] Each effect has wet/dry, bypass, and type-specific parameters
- [ ] AudioKit effects nodes wired into per-node signal chain
- [ ] Richer oscillator: ADSR envelope, filter with cutoff/resonance
- [ ] Sound preset system: save/load `SoundPatch` configurations
- [ ] Visual feedback: subtle animation on nodes while they play (pulse, glow)

**Deliverable**: Nodes sound rich. Each branch has its own character through synthesis and effects.

---

### Phase 5: Claude as Gardener

**Goal**: AI-assisted music creation at all levels.

- [ ] Claude API integration (Haiku 4.5 as default)
- [ ] Build `GenerationContext` → prompt serializer
- [ ] Build response parser: Claude JSON → `NoteSequence` (+ optional `SoundPatch`, `Effect`)
- [ ] Claude prompt input in Bloom UI (below selected node)
- [ ] Node-level generation: "Give me a minor arpeggio, 4 beats, sparse"
- [ ] Variation generation: "Give me 3 variations of this sequence"
- [ ] Variation audition UI: preview generated options, accept/reject
- [ ] Tree-level generation: "Add a bass branch that complements this melody"
- [ ] Musical context extraction: automatically detect key, scale from existing sequences
- [ ] Model selector: Haiku for fast generation, Sonnet for complex requests
- [ ] Generation history: undo/redo generated content

**Deliverable**: Select a node, type "chill lo-fi chords in Cm", hear it. The gardener is tending the tree.

---

### Phase 6: Forest — Multiple Trees & Arrangement

**Goal**: Build a track from multiple Node Trees.

- [ ] Implement multi-tree project: create, duplicate, delete trees
- [ ] "Duplicate & Mutate" workflow: clone a tree, modify branches
- [ ] Arrangement view: compact tree visualizations side by side
- [ ] Tree-to-tree transitions: quantized to cycle boundary (default)
- [ ] Per-tree transition override: manual beat count
- [ ] Ableton-style clip launch quantization for transitions
- [ ] Crossfade between trees (configurable length)
- [ ] Master output: mix all tree playback into stereo out
- [ ] Export: render arrangement traversal to WAV/MP3

**Deliverable**: Build 4-5 trees that tell a musical story. Play them in sequence. Export a track.

---

### Phase 7: Traversal Modes — The Performance Layer

**Goal**: Playback modes turn arrangement into instrument.

- [ ] Sequential mode (default): play trees in order
- [ ] Ping-pong mode: forward then reverse
- [ ] Random mode: any tree, any time
- [ ] Brownian mode: random walk to adjacent trees
- [ ] Custom mode: user-defined traversal order
- [ ] Traversal mode selector in arrangement view
- [ ] Live mode: switch traversal modes during playback
- [ ] "Capture" feature: record a live traversal as a fixed arrangement
- [ ] Visual: highlight active tree, show traversal path history

**Deliverable**: Same 5 trees produce completely different tracks depending on traversal mode. The DAW is now an instrument.

---

### Phase 8: Polish & Ship

**Goal**: Production quality for v1.0 release.

- [ ] Bloom UI animations: smooth open/close/transfer
- [ ] Canvas transitions: zoom between tree view and arrangement view
- [ ] Keyboard shortcuts for all core actions
- [ ] Undo/redo system across all operations
- [ ] Project browser: create, open, recent projects
- [ ] Performance optimization: audio thread safety, UI responsiveness
- [ ] Visual polish: consistent design language, dark theme refinement
- [ ] Onboarding: first-launch experience that teaches seed → tree → track
- [ ] Crash reporting and error handling
- [ ] App Store preparation: icon, screenshots, description

**Deliverable**: Canopy v1.0 — ready for the world.

---

## Implementation Agent Instructions

When using Claude Code to implement this plan:

1. **Read this entire document first** before writing any code.
2. **Create a TodoWrite task list** from the current phase's checklist before starting implementation.
3. **Work phase by phase** — do not skip ahead. Each phase builds on the previous.
4. **The data model is sacred** — implement it exactly as specified in Phase 1. Everything else plugs into it.
5. **Test each phase** before moving to the next. Each phase has a clear deliverable — verify it works.
6. **Commit frequently** with descriptive messages referencing the phase and task.
7. **No band-aids** — if something doesn't fit the architecture, raise it. Don't hack around it.
8. **AudioKit is your friend** — use it for synthesis, effects, and mixing. Don't reinvent DSP.
9. **Claude API integration** (Phase 5) should be behind a protocol so the model can be swapped easily.
10. **The canvas is constrained** — bounded by tree extent, not infinite. This is a deliberate design choice.

---

*Canopy — where music grows.*
