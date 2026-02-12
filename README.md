# Canopy

**Where music grows.**

A procedural DAW where music emerges from Node Trees, not timelines. Instead of tracks and arrangements, Canopy uses living, branching structures — each branch is a musical layer that plays simultaneously. Different branch lengths create natural polyrhythm. Songs progress by traversing a sequence of trees.

## How It Works

**Seed → Tree → Track**

Every session starts with a single node — a seed. You give it a voice (a synth, a sequence), then grow branches from it. Each branch loops at its own length, creating organic polyrhythm as a natural consequence of the structure. Build multiple trees and arrange them into a track using traversal modes that turn playback into performance.

### Three Ways to Create

- **Play** — On-screen keyboard writes directly to a node
- **Sequence** — Step sequencer grid for precise pattern building
- **Describe** — Tell Claude what you want ("chill lo-fi chords in Cm") and hear it

### Traversal Modes

The same set of trees produces completely different tracks depending on how you traverse them:

- **Sequential** — Play trees in order
- **Ping-Pong** — Forward then reverse
- **Brownian** — Random walk to adjacent trees
- **Random** — Any tree, any time
- **Custom** — User-defined path

## Tech Stack

- **Platform**: macOS (native)
- **Language**: Swift
- **UI**: SwiftUI + AppKit interop
- **Audio**: AVAudioEngine + AudioKit
- **AI**: Claude API
- **Files**: `.canopy` (JSON-based project format)

## Building

Requires macOS 13+ and Xcode 15+.

```bash
swift build
```

Or open `Package.swift` in Xcode and run.

## Status

Early development — building the foundation. See the [build plan](https://github.com/voislavcodes/canopy/blob/main/docs/build-plan.md) for the full roadmap.

## License

All rights reserved.
