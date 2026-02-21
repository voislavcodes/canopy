# Binaural Stereo Width — Design Document

How Canopy's WIDTH parameter creates spatial spread using psychoacoustic binaural cues instead of simple L/R panning. Implemented in FLOW, this document describes the technique generically so it can be adapted to TIDE, SWARM, and future engines.

---

## The Problem with Pan-Based Width

Traditional stereo width uses amplitude panning — split signal components between L and R at different levels. This works, but the result sounds like "things placed in a room." On headphones especially, hard-panned elements feel stuck to one ear.

The UDO Super 6 takes a different approach: each ear gets a slightly different version of the *same* signal. The brain interprets tiny frequency and timbral differences between ears as spatial information — width, depth, immersion. This is binaural stereo.

## Core Principle

**One signal source, two slightly different renderings.**

The L and R channels render from the same musical content (same note, same partials, same modulation) but with three layers of controlled decorrelation:

1. **Frequency detune** — sub-3Hz differences that create binaural beating
2. **Modulation decorrelation** — each ear hears a slightly different "perspective" on the same modulation
3. **Timbral variation** — subtle differences in harmonic content between ears

At `width=0`, L and R are identical (mono). As width increases, the three layers gradually diverge.

## Layer 1: Binaural Frequency Detune

The primary spatial cue. L and R oscillators/partials run at slightly different frequencies:

```
binauralDetune = width * (partialIndex / maxPartials) * maxDetuneHz
freqR = freqL + binauralDetune
```

Key design choices:

- **Max detune: 3 Hz.** Binaural beating above ~4 Hz becomes audible roughness rather than spatial width. Under 3 Hz it's felt, not heard.
- **Scales with harmonic index.** The fundamental gets zero detune (keeps bass locked center — critical for musicality). Upper partials get progressively more detune. This matches how real acoustic spaces work: high frequencies carry more spatial information.
- **Always sub-perceptual.** The listener shouldn't hear "detuning" — they should feel "wideness."

### Adaptation per engine

| Engine | What gets detuned | Scaling factor |
|--------|-------------------|----------------|
| FLOW | 64 sine partials | `i / 63.0 * 3.0 Hz` — linear with harmonic index |
| TIDE | 16 SVF bandpass center freqs | `i / 15.0 * 2.0 Hz` — less detune since bands are broader |
| SWARM | 16 sine partials | `(pos[i] / 64.0) * 3.0 Hz` — scale with orbital position |
| SPORE | Per-grain pitch | `±(0–1.5) Hz` random per grain — fits stochastic nature |

## Layer 2: Modulation Decorrelation

Each engine has modulation sources (fluid physics, tidal patterns, orbital forces, grain scheduling). The R channel receives slightly different modulation targets than L.

In FLOW this happens at control rate (every 64 samples):

```
if width > 0.001 {
    decorr = width * noise * 0.5
    freqOffsetR = freqTargetL + decorr * 2.0   // slightly different freq mod
    ampScaleR = ampTargetL * (1.0 + decorr * 0.1) // slightly different amp mod
} else {
    // R tracks L exactly
    freqOffsetR = freqOffsetL
    ampScaleR = ampScaleL
}
```

The noise source should be deterministic and per-partial (not random per sample) so the decorrelation is stable and smooth, not jittery:

```swift
// Deterministic noise from existing state — no RNG mutation needed
let stereoNoise = quickNoise(partial.laminarPhase + Double(i)) * 0.5
```

### Adaptation per engine

| Engine | What gets decorrelated | How |
|--------|----------------------|-----|
| FLOW | Fluid freq/amp offsets per partial | R gets noise-offset targets from same fluid simulation |
| TIDE | Band level VCA targets | R band levels offset by `width * noise * 0.05` from tidal pattern |
| SWARM | Orbital positions/forces | R partials use slightly different gravitational pull |
| SPORE | Already decorrelated | Grains already have random pan; width just controls spread range |

## Layer 3: Timbral Variation

Each ear gets subtly different harmonic content. In FLOW this is phase modulation depth:

```
pmDepthR = pmDepthL * (1.0 + width * 0.15)
```

At full width, the R ear's PM depth is 15% higher — enough to create timbral difference that the brain reads as spatial information, not enough to sound like a different instrument.

### Adaptation per engine

| Engine | Timbral difference source |
|--------|--------------------------|
| FLOW | PM depth ×(1 + width×0.15) for R channel |
| TIDE | SVF Q slightly different per band L vs R (`q ± width * 0.1`) |
| SWARM | Waveshaping amount slightly different for R |
| SPORE | Grain waveform mix slightly offset for R |

## Implementation Requirements

### Per-voice state

Each voice needs independent R-channel state for anything that accumulates over time (phases, filter state). For FLOW this meant adding to `FlowPartial`:

```swift
var phaseR: Double = 0
var pmPhaseR: Double = 0
var freqOffsetR: Double = 0
var freqOffsetStepR: Double = 0
var ampScaleR: Double = 1
var ampScaleStepR: Double = 0
```

**Critical:** R-channel phases must start at 0 on `beginNote()`, same as L. Notes always begin in phase — width builds over time through the frequency detune creating gradual phase divergence.

### Signal chain order

```
Oscillator/partials (L + R independently)
    → SVF filter (independent L/R state — do NOT share filter state)
    → WARM processStereo
    → Envelope × velocity (LAST — gates WARM noise artifacts)
```

The envelope must be the final multiplier. If envelope comes before WARM, WARM's internal noise/saturation state rings after the note releases.

### SVF filter: independent L/R

When the voice has a per-voice SVF, it needs independent state per channel:

```swift
private var svfLowL: Double = 0, svfBandL: Double = 0
private var svfLowR: Double = 0, svfBandR: Double = 0
```

Do NOT reset SVF state on note retrigger (avoids clicks — same as SPORE).

### Manager-level stereo

The voice manager sums L/R independently, then applies node-level processing:

```swift
mutating func renderStereoSample(sampleRate: Double) -> (Float, Float) {
    let (l0, r0) = voices.0.renderStereoSample(sampleRate: sampleRate)
    // ... all voices ...
    var mixL = l0 + l1 + ... + l7
    var mixR = r0 + r1 + ... + r7

    // Node-level WARM power sag (stereo)
    (mixL, mixR) = WarmProcessor.applyPowerSag(&warmNodeState, sampleL: mixL, sampleR: mixR, warm: warmLevel)

    // Safety tanh
    let outL = Float(tanh(Double(mixL) * gain) * scale)
    let outR = Float(tanh(Double(mixR) * gain) * scale)
    return (outL, outR)
}
```

Mono `renderSample()` becomes a wrapper: `let (l, r) = renderStereoSample(...); return (l + r) * 0.5`

### NodeAudioUnit render path

Follow the SWARM/TIDE pattern — stereo throughout:

```swift
let (rawL, rawR) = engine.renderStereoSample(sampleRate: sr)
let volF = Float(volumeSmoothed)
var sampleL = filter.process(rawL * volF)
var sampleR = filter.process(rawR * volF)
(sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)
// pan law on stereo pair
ablPointer[0]...[frame] = sampleL * gainL
ablPointer[1]...[frame] = sampleR * gainR
```

### Zero-cost at width=0

When width is 0, R phases track L exactly (same frequency, started in sync), so `mixR == mixL` naturally. The extra sin() calls still happen — to avoid them entirely, use the `doStereo` flag:

```swift
let doStereo = widthParam > 0.001
// ... render L always, render R only if doStereo ...
if !doStereo { mixR = mixL }
```

For engines where the R channel cost is significant (FLOW with 64 partials), this optimization matters. For engines with fewer oscillators (SWARM with 16), the branch overhead may not be worth it.

## Config / UI / AudioCommand

Each engine's config struct gets:

```swift
var width: Double = 0.5   // 0–1: binaural stereo spread
```

FlowPanel UI pattern (reuse for other panels):

```swift
paramSlider(label: "WDTH", value: $localWidth, range: 0...1,
            format: { "\(Int($0 * 100))%" }) {
    commitConfig { $0.width = localWidth }
} onDrag: { pushConfigToEngine() }
```

AudioCommand cases need the width param added to their respective `.set*` cases.

## Why This Sounds Good

- **Binaural beating (0–3 Hz)** is the brain's primary mechanism for perceiving spatial width in headphone listening. It's the same phenomenon that makes real concert halls sound "wide" — reflections create tiny frequency differences between ears.
- **Decorrelated modulation** means each ear hears a different "perspective" on the same turbulence/pattern/orbit. Like standing in a room where the reverb is slightly different at each ear position.
- **Timbral variation** reinforces the spatial impression — real sound sources always have slightly different frequency response to each ear due to head shadow and pinna filtering.
- **Width=0 is true mono.** No artifacts, no phase issues, no comb filtering. The effect builds gradually and continuously.

## Reference

- UDO Super 6: binaural mode with independent filter paths per ear
- Dave Smith Prophet Rev2: binaural pan spread with per-voice detune
- Eventide ShimmerVerb: frequency-shifted reflections creating spatial depth
