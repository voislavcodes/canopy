---
name: dsp-guard
description: Loaded when writing or modifying audio/DSP code (Audio/, oscillators, effects, render callbacks, AVAudioEngine). Contains hard-won anti-patterns that prevent subtle bugs like signal death, self-oscillation, and clicks.
user-invocable: false
---

# DSP Guard

When writing or reviewing any audio/DSP code in this project, you MUST follow these rules. Every one of these was learned from a real bug.

## Rule 1: Parameters control character, never signal survival

If setting a parameter to its minimum or maximum can kill the signal or blow it up, the mapping is wrong.

**Bad** — filter coefficient as parameter (coeff→0 = frozen = silence):
```swift
dampLP += coeff * (input - dampLP)
```

**Good** — fixed LP as reference, parameter blends:
```swift
dampLP += 0.5 * (input - dampLP)           // fixed reference
output = input + (dampLP - input) * amount  // amount=0: clean, amount=0.6: dark
```

## Rule 2: Dead zone for near-unity pitch shifts

A 2-grain overlap-add shifter at sub-3-cent shifts creates near-identical overlapping grains → comb filtering → destructive interference. In a feedback loop this compounds.

**Fix**: If shift is negligible, bypass the shifter entirely.

## Rule 3: Tie damping to excitation in feedback loops

Any process that adds energy (saturation, resonant filters) inside a feedback network can exceed per-pass loss.

```swift
hfDampCoeff = baseDamping + excitationAmount * 0.15
```

Self-balancing — as excitation rises, damping rises proportionally.

## Rule 4: Correct Schroeder allpass topology

The wrong sign in buffer write creates frequency-dependent gain (+14dB bass boost through 4 stages at g=0.5), causing self-oscillation in feedback loops.

**Wrong:**
```swift
output = -g * input + delayed
buf[write] = input + g * delayed    // wrong sign
```

**Correct:**
```swift
v = input - g * delayed
buf[write] = v
output = g * v + delayed
// |H| = 1 at all frequencies
```

If an allpass chain seems to add "warmth," verify it's actually unity gain.

## Rule 5: No gain sources inside feedback loops

Any gain > 1.0 in the feedback path caps max feedback below 1/gain. Even +1.5dB caps feedback at 0.84.

**Fix**: Move additive coloring (bass boost, saturation harmonics) to the output path AFTER the feedback write.

## Rule 6: ADAA must use Double precision

First-order ADAA computes `(F(x) - F(prev)) / (x - prev)`. When consecutive samples are close, Float32 (~7 digits) cancels, producing audible crackle. Oversampling makes it worse (samples closer together).

```swift
// ALWAYS Double for the difference quotient
let dx = Double(x); let dprev = Double(prevX)
let dResult = (saturateAntiderivD(dx) - saturateAntiderivD(dprev)) / (dx - dprev)
return Float(dResult)
```

Use `log1p` instead of `log(1+x)` for antiderivatives.

## Rule 7: Buffer-level fade for live graph topology changes

Volume-level fades don't work — FX chains retain energy, disconnects produce artifacts at buffer boundaries.

**Pattern**: Atomic `fadeState` (0=normal, 1=fading, 2=faded). Static `applyFade` runs at END of every render callback, AFTER all synthesis + FX:
- State 1: linear ramp 1→0 over one buffer (~11ms), then set state 2
- State 2: `memset` zeros
- Main thread: `requestFadeOut()`, poll `isFadedOut` in 1ms increments (30ms cap), then disconnect

**Corollary**: Don't reset fade state at stop time. Reset in `startAll()` right before next playback. Sequence: fade→confirm→stop (stay faded) ... resetFade→start.

## General Render Callback Rules

- Lock-free: no allocations, no Swift reference counting, no ObjC messaging
- Pre-allocate all buffers via `UnsafeMutablePointer<Float>`
- Tagged enum `EffectSlot` — no protocol existentials on audio thread
