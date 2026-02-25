# Canopy Architecture Reference

Last updated: 2026-02-25

---

## Layer Map

```
Models (Foundation only)      — Pure data, Codable, no logic
  |
State  (Combine + Foundation) — Business logic, @Published, mutations
  |
Views  (SwiftUI)              — Thin clients, read state, dispatch actions
  |
Audio  (AVFoundation only)    — Lock-free DSP, render callbacks, effects

Services (Foundation/AppKit)  — Stateless utilities (file I/O, quantization)
```

No cross-contamination: Views never import AVFoundation. Audio never imports SwiftUI.

---

## Data Flow: Main Thread to Audio Thread

```
┌─────────────────────────────────────────────────────────┐
│  MAIN THREAD                                            │
│                                                         │
│  SwiftUI Views ─── mutations ──▶ ProjectState           │
│       ▲                              │                  │
│       └────── @Published ────────────┘                  │
│                                                         │
│  ProjectState sync methods:                             │
│    syncNodeFXToEngine()                                 │
│    syncMasterBusToEngine()                              │
│    rebuildArpPool()                                     │
│              │                                          │
│              ▼                                          │
│  AudioEngine.shared                                     │
│    ├── TreeAudioGraph (units: [UUID: NodeAudioUnit])    │
│    └── MasterBusAU (vol + FX + Shore limiter)           │
│              │                                          │
│         push commands                                   │
│              ▼                                          │
│  AudioCommandRingBuffer (SPSC, 256 slots, lock-free)    │
└──────────────┬──────────────────────────────────────────┘
               │ drain on callback
               ▼
┌─────────────────────────────────────────────────────────┐
│  AUDIO THREAD (per ~512 sample buffer @ 48kHz)          │
│                                                         │
│  Per NodeAudioUnit:                                     │
│    1. Drain command buffer                              │
│    2. Per sample:                                       │
│       seq.tick(globalClock) → noteOn/noteOff            │
│       voices.renderSample() → raw                      │
│       filter.process(raw) → filtered                   │
│       lfoBank.tick() → modulation                      │
│       fxChain.processStereo() → (L,R)                  │
│       pan law → stereo output                          │
│    3. Update beat/playing pointers (UI polling)         │
│                                                         │
│  MasterBusAU (AFTER all source nodes):                  │
│    pull → masterVol → masterFX → Shore → output         │
│    advance clockSamplePosition += frameCount            │
└─────────────────────────────────────────────────────────┘
```

---

## Audio Graph Topology

Flat — all source nodes connect directly to mainMixer. No sub-mixers.

```
Node A ─┐
Node B ──┼──▶ Main Mixer ──▶ MasterBusAU ──▶ Output
Node C ─┘
```

### Per-Node Audio Subgraph

```
Sequencer ──▶ VoiceManager ──▶ MoogFilter ──▶ FXChain ──▶ Pan ──▶ Output
   │              │                 ▲
   │         (1 of 11 engines)   LFOBank (vol/pan/cut/res)
   │
   ├── Forward/Reverse/PingPong/Random/Brownian playback
   ├── Ratcheting (32 slots pre-alloc)
   ├── Mutation (pitch shift, freeze/thaw)
   ├── Per-step probability
   └── Arp mode (pool-based, up/down/random)
```

### 11 Synth Engines

| Engine | Type | Topology |
|--------|------|----------|
| Oscillator | Subtractive | 8-voice poly, 5 waveforms (sine/tri/saw/sq/noise) |
| FMDrum | FM percussion | 8-voice GM kit, carrier+mod, one-shot |
| WestCoast | Complex osc | Primary+mod → wavefolder → LPG (vactrol) |
| FLOW | Additive/fluid | 64 partials, Reynolds-driven regime transitions |
| TIDE | Spectral | 16 frames, band-level sequencing |
| SWARM | Additive/physics | 64 partials, gravity+flock+scatter |
| QUAKE | Physics drums | 6-voice, mass/surface/force per voice |
| SPORE | Granular | Stochastic grain triggering, density/form/focus |
| FUSE | Analog circuit | Schmitt trigger osc → Moog filter → ADSR |
| VOLT | Circuit drums | 4 topologies (resonant/noise/metallic/tonal) per slot |
| SCHMYNTH | Subtractive | Schmitt circuit poly, cutoff+res+warm |

### 12 Effect Types

| Effect | DSP | Stereo |
|--------|-----|--------|
| Color | Moog ladder + SVF (LP/HP/BP) | Mono (L/R independent) |
| Heat | tanh waveshaping + tone LP | Mono |
| Echo | Ring buffer delay + diffusion | Mono |
| Space | Freeverb (4 comb + 2 allpass) | Mono |
| Pressure | Envelope follower compressor | Mono |
| Drift | Traveling delay (air/water/metal) | True stereo |
| Tide | Cascaded all-pass phaser | Mono |
| Terrain | 3-band parametric EQ (biquad) | Mono |
| Level | Gain staging utility | Mono |
| Ghost | Recursive feedback + binaural | True stereo |
| Nebula | 6-tap FDN reverb, evolving | True stereo |
| Melt | FFT spectral gravity shifting | True stereo |

---

## State Object Hierarchy

```
AppDelegate
  ├── ProjectState     — musical data, triggers re-renders on edit
  ├── TransportState   — play/stop/bpm, thin wrapper over AudioEngine
  └── CanopyWindow
        └── MainContentView
              ├── @EnvironmentObject ProjectState
              ├── @EnvironmentObject TransportState
              ├── @StateObject CanvasState     — pan/zoom, 60fps, isolated
              ├── @StateObject BloomState      — panel positioning, ephemeral
              └── @StateObject ViewModeManager — forest / focus mode
```

CanvasState is deliberately separated from ProjectState so zoom/pan gestures (60fps) never trigger tree re-renders.

---

## View Hierarchy

```
MainContentView
├── ToolbarView
│   ├── TransportView (play/stop, BPM drag)
│   ├── Scale selector (root + mode)
│   └── Computer keyboard toggle
│
├── [Forest mode] CanopyCanvasView
│   ├── BranchLineView (parent→child lines)
│   ├── NodeView (per node)
│   ├── AddBranchButton + PresetPickerView
│   └── Bloom panels (outside scaleEffect):
│       ├── ForestEngineView   → dispatches to 11 engine panels
│       ├── ForestSequencerView → pitched/drum/orbit/sporeSeq
│       └── ForestKeyboardView  → keyboard/padGrid
│
├── [Focus mode] FocusView
│   ├── Panel indicator (ENGINE / SEQUENCER / INPUT)
│   └── Full-frame engine/sequencer/keyboard view
│
└── BottomLaneView
    ├── FX tab (effect strip + parameter popovers)
    └── MOD tab (LFO strip + routing popovers)
```

---

## Keyboard Input Pipeline

```
Computer Key Press
  → CanopyWindow.sendEvent() intercepts NSEvent
  → AppDelegate.handleKeyDown()
     ├── AudioEngine.shared.noteOn(pitch, nodeID)   ← sound
     ├── projectState.captureBuffer.noteOn(...)      ← recording
     └── projectState.computerKeyPressedNotes.insert ← visual

On-Screen Keys (KeyboardBarView / DrumPadGridView)
  ├── AudioEngine.shared.noteOn(pitch, nodeID)
  ├── projectState.captureBuffer.noteOn(...)
  └── local @State pressedNotes

Capture: buffer → PhraseDetector → CaptureQuantizer → node.sequence.notes
```

All three input paths (computer keyboard, on-screen, future MIDI) write to the same NoteSequence.

---

## Thread Safety Model

**Lock-free guarantees on audio thread:**

1. SPSC ring buffer for commands (main → audio)
2. Pre-allocated arrays in Sequencer (128 event slots, 32 ratchet slots)
3. Value types + tuples throughout (no ARC on render callback)
4. Unsafe pointers for cross-thread state polling (beat position, playing flag)
5. No ObjC messaging in render path

**Shared cross-thread pointers:**

| Pointer | Written by | Read by | Sync |
|---------|-----------|---------|------|
| `clockSamplePosition` (Int64*) | MasterBusAU | All source nodes | Pull model |
| `clockIsRunning` (Bool*) | Main thread | All source nodes | Flag only |
| `_currentBeat` (Double*) | Audio thread | Main thread (UI) | Stale OK |
| `_isPlaying` (Bool*) | Audio thread | Main thread (UI) | Stale OK |
| `masterFXChain` (EffectChain*) | Main thread (swap) | MasterBusAU render | Pointer swap |

---

## Key Architectural Invariants

1. Every `NodeTree` has exactly one root `Node`
2. Every `Node` must have a parent (except root)
3. `NoteSequence.lengthInBeats` matches `Node.lengthInBeats`
4. Tree cycle = LCM of all branch `lengthInBeats` — polyrhythm is emergent
5. Models are pure data (no business logic, no UI imports)
6. State objects own all business logic
7. Views are thin — read state, dispatch actions
8. Audio code never imports SwiftUI; UI code never imports AVFoundation
9. No allocations on the audio thread — everything pre-allocated at init
10. Command ring buffer is the only main→audio communication channel

---

## File Organization

```
Sources/Canopy/
├── main.swift                    App entry (NSApplication bootstrap)
├── App/
│   ├── AppDelegate.swift         Window lifecycle, keyboard routing, menu
│   ├── CanopyWindow.swift        NSWindow subclass (key event intercept)
│   └── MainContentView.swift     Root SwiftUI view, audio sync
├── Models/                       Sacred data model (Codable structs)
│   ├── CanopyProject.swift       Project root (trees, arrangements, LFOs)
│   ├── NodeTree.swift            Tree with root Node
│   ├── Node.swift                Recursive node (sequence + patch + children)
│   ├── NoteSequence.swift        Musical content (events, EUC, mutation, arp)
│   ├── SoundPatch.swift          11 engine configs + filter + envelope
│   ├── Effect.swift              12 effect types + legacy migration
│   ├── MusicalTypes.swift        PitchClass, ScaleMode, MusicalKey
│   ├── Arrangement.swift         Multi-tree arrangement (future phase)
│   ├── Modulation.swift          LFO definitions + routing
│   ├── NodePreset.swift          Preset archetypes
│   ├── OrbitConfig.swift         Gravitational rhythm config
│   ├── QuakeConfig.swift         Physics percussion config
│   └── VoltConfig.swift          Circuit drum config
├── State/
│   ├── ProjectState.swift        Central musical state (709 lines)
│   ├── TransportState.swift      Play/stop/BPM
│   ├── CanvasState.swift         Pan/zoom (isolated from project)
│   ├── BloomState.swift          Panel positioning
│   ├── ViewModeManager.swift     Forest / Focus mode
│   └── MIDICaptureBuffer.swift   Keyboard recording buffer
├── Audio/
│   ├── AudioEngine.swift         Singleton, graph management, command dispatch
│   ├── TreeAudioGraph.swift      Node → NodeAudioUnit mapping
│   ├── NodeAudioUnit.swift       Render callback factory (12 paths)
│   ├── Sequencer.swift           Beat clock, event triggering (1000 lines)
│   ├── VoiceManager.swift        8-voice polyphonic pool
│   ├── MoogLadderFilter.swift    24dB/oct Huovilainen model
│   ├── LFOProcessor.swift        4-slot LFO bank per node
│   ├── MasterBusAU.swift         In-process AU (master FX + Shore + clock)
│   ├── RingBuffer.swift          SPSC command buffer + circular audio buffer
│   ├── Effects/                  12 effect implementations + EffectSlot + EffectChain
│   ├── [Voice files]             Per-engine voice managers
│   ├── SchmittCircuit.swift      Analog circuit model (FUSE/VOLT)
│   ├── ImprintRecorder.swift     Spectral analysis from mic
│   └── SpectralAnalyser.swift    FFT utilities
├── Views/                        42 SwiftUI view files across 8 subdirs
├── Services/
│   ├── ProjectFactory.swift      New project creation
│   ├── ProjectFileService.swift  JSON persistence
│   ├── ProjectPersistenceService.swift  Directory management
│   ├── ScaleResolver.swift       Node → effective scale resolution
│   ├── CaptureQuantizer.swift    MIDI capture → quantized notes
│   ├── PhraseDetector.swift      Best phrase extraction from buffer
│   ├── EuclideanRhythm.swift     Bjorklund's algorithm
│   └── SequenceFillService.swift Pattern generation
└── Theme/
    ├── CanopyColors.swift        Design tokens
    └── CanvasScaleEnvironment.swift  Environment key for zoom level
```

---

## Backward Compatibility

Custom `init(from:)` decoders on: CanopyProject, Node, NoteSequence, Effect, OrbitConfig, QuakeConfig, VoltConfig, SoundPatch. Missing fields decode to sensible defaults. `CanopyProject.migrate()` handles format upgrades. Legacy effect types (`reverb`, `delay`, etc.) map to canonical Canopy types via `EffectType.canonical`.
