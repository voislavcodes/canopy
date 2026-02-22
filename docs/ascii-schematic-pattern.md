# ASCII Schematic Visualization Pattern

Design doc for the reactive ASCII circuit schematic technique used in FusePanel.
Reference implementation: `Sources/Canopy/Views/Bloom/FusePanel.swift`

## Core Idea

Replace Canvas stroke-based schematics with **Unicode box-drawing characters rendered as text** inside a SwiftUI `Canvas`. Each character is drawn individually via `context.draw(Text(...))`, giving per-character color, opacity, weight, and positioning control while maintaining a monospaced terminal aesthetic.

## Architecture

```
TimelineView(.animation(minimumInterval: 1/15))
  └─ Canvas { context, size in ... }
       ├─ drawChar()       — single character at a point
       ├─ drawCharBold()   — bold weight variant
       └─ drawString()     — string of chars, each cell = cellW wide, centered on X
```

### Grid System

Everything sits on a virtual character grid:

```swift
let fontSize: CGFloat = max(10, 11 * cs)    // scales with canvas scale
let cellW: CGFloat = fontSize * 0.62         // monospaced char width ≈ 0.6× height
let rowH: CGFloat = fontSize * 1.35          // row spacing with breathing room
let baseY = h * 0.06                         // top margin
func rowY(_ row: Int) -> CGFloat { baseY + CGFloat(row) * rowH }
```

Characters are placed at fractional positions (e.g. `w * 0.28` for left element, `w * 0.72` for right), not strict grid columns. This allows the layout to adapt to canvas width while keeping the monospaced character feel.

### Three Drawing Primitives

```swift
// Single char at exact position
drawChar(context, "═", at: CGPoint(x, y), size: fontSize, color: wireColor)

// Bold variant
drawCharBold(context, "A", at: CGPoint(x, y), size: fontSize, color: labelColor)

// String centered on X — each char placed cellW apart
drawString(context, "┌───Body───┐", centerX: w * 0.5, y: rowY(9),
           cellW: cellW, fontSize: fontSize, color: bodyColor, bold: true)
```

## Unicode Character Palette

### Wiring
| Char | Unicode | Use |
|------|---------|-----|
| `─`  | U+2500  | Horizontal wire / rail |
| `│`  | U+2502  | Vertical wire |
| `┌`  | U+250C  | Top-left corner |
| `┐`  | U+2510  | Top-right corner |
| `└`  | U+2514  | Bottom-left corner |
| `┘`  | U+2518  | Bottom-right corner |
| `┬`  | U+252C  | Junction (T-down) |

### Double-line (heavy body / high resonance)
| Char | Unicode | Use |
|------|---------|-----|
| `═`  | U+2550  | Heavy horizontal |
| `║`  | U+2551  | Heavy vertical |
| `╔`  | U+2554  | Heavy top-left |
| `╗`  | U+2557  | Heavy top-right |
| `╚`  | U+255A  | Heavy bottom-left |
| `╝`  | U+255D  | Heavy bottom-right |

### Components
| Char | Unicode | Use |
|------|---------|-----|
| `╪`  | U+256A  | Capacitor center (crossbar) |
| `╲`  | U+2572  | Diagonal wire (left-to-right down) |
| `╱`  | U+2571  | Diagonal wire (right-to-left down) |
| `▼`  | U+25BC  | Output arrow |

### Fill / Energy Indicators
| Char | Unicode | Use |
|------|---------|-----|
| `░`  | U+2591  | Light fill (low energy) |
| `▒`  | U+2592  | Medium fill |
| `▓`  | U+2593  | Dense fill |
| `█`  | U+2588  | Full block (max energy) |

### Shape Indicators
| Char | Unicode | Use |
|------|---------|-----|
| `△`  | U+25B3  | Triangle wave |
| `◇`  | U+25C7  | Transitional |
| `○`  | U+25CB  | Sine-like |
| `□`  | U+25A1  | Square wave |

## Reactivity Pattern

Each synth parameter drives one or more visual properties of the ASCII characters. The mapping follows the rule: **the schematic should look like the circuit feels.**

### FUSE Example

| Parameter | Visual Effect | Implementation |
|-----------|--------------|----------------|
| **Soul** (supply voltage) | Block fill chars inside caps cycle `░→▒→▓→█`. Vcc rail brightness increases. Flicker between adjacent fill levels at 15fps. | `soulChar` selected by threshold, `sin(time*5)` toggles between adjacent chars |
| **Tune** (frequency ratio) | Cap B shifts down by `tune * 4 * cs`. Ratio text (e.g. "2.0×") fades in between A and B. | `capBYOffset` applied to all B-related rows |
| **Couple** (circuit interaction) | `╲╱` diagonal chars go from dim (`0.15` opacity) to bright accent (`0.9`). Shimmer via `sin(time*6)` at high values. "(couple)" label fades in. | `coupleOp = 0.15 + couple * 0.75`, shimmer added when `> 0.3` |
| **Body** (resonance) | Box border upgrades from single-line `┌─┐` to double-line `╔═╗`. Internal `░` glow fill. Wobble via X offset at high values. | Character set swap at `body > 0.5`, wobble = `sin(time*8) * 1.5 * amount` |
| **Color** (waveshape) | Shape indicator near caps morphs: `△→◇→○→□` | Threshold selection at 0.25 intervals |

### Animation via TimelineView

- **Rate**: 15fps (`1/15` interval) — enough for visible character transitions, not wasteful
- **Time source**: `timeline.date.timeIntervalSinceReferenceDate` passed to draw function
- **Patterns used**:
  - `sin(time * freq)` for smooth oscillation (Vcc pulse, body wobble, couple shimmer)
  - Threshold comparison against sin for flicker (soul fill char alternation)
- **Rule**: Animation is accent, not distraction. Only elements that represent energy/activity animate.

## Applying to Other Synths

### Design Process

1. **Identify the signal flow** — what are the conceptual stages? (oscillators → filter → output, etc.)
2. **Map to ASCII topology** — lay out as a vertical flow diagram using box-drawing chars
3. **Assign characters to components** — use the palette above, invent new ones as needed
4. **Wire parameters to visuals** — each param should change exactly one visual property
5. **Add animation sparingly** — only where it represents real energy in the circuit

### Potential Mappings for Other Engines

**Flow** (waveguide): String as horizontal `════` rail, exciter as `╳`, reflections as `◁ ▷` bouncing
**Swarm** (particle additive): Dot field using `· • ● ◉` at frequency positions
**Tide** (spectral): Vertical bars `▁▂▃▄▅▆▇█` as spectrum bins
**Spore** (granular): Scattered `·` chars that cluster/disperse with density param
**West Coast** (wavefolder): Sine char `∿` that gets progressively squared `⊓` with fold amount

### Key Sizing Rules

- Font size: `max(10, 11 * cs)` — scales with bloom panel canvas scale
- Cell width: `fontSize * 0.62` — standard monospaced width ratio
- Row height: `fontSize * 1.35` — comfortable line spacing
- Canvas height: `180 * cs` for ~13 rows, adjust per engine complexity
- Element positions: use fractional `w *` for horizontal, `rowY(n)` for vertical

## Why This Works

1. **Monospaced fonts are inherently technical** — immediately reads as "circuit / code / system"
2. **Box-drawing chars have more character than stroked lines** — they carry the weight of terminal culture
3. **Per-character control** — each char can have independent color, opacity, weight
4. **Scales cleanly** — monospaced text at any size still reads as monospaced text
5. **Low render cost** — Canvas text drawing is lightweight, 15fps is gentle
6. **Reactive without being noisy** — character swaps (░→▓, ┌→╔) are discrete state changes, not continuous motion
