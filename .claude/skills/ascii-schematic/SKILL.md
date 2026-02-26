---
name: ascii-schematic
description: Loaded when building synth panel UIs, bloom panels, or ASCII visualizations. Contains the grid system, character palette, drawing primitives, and reactivity patterns for the ASCII circuit schematic technique.
user-invocable: false
---

# ASCII Schematic Visualization

When building any synth panel or parameter visualization UI in Canopy, use this technique. Reference implementation: `Sources/Canopy/Views/Bloom/FusePanel.swift`

## Architecture

```
TimelineView(.animation(minimumInterval: 1/15))
  └─ Canvas { context, size in ... }
       ├─ drawChar()       — single character at a point
       ├─ drawCharBold()   — bold weight variant
       └─ drawString()     — string of chars, each cell = cellW wide
```

## Grid System

```swift
let fontSize: CGFloat = max(10, 11 * cs)    // scales with canvas scale
let cellW: CGFloat = fontSize * 0.62         // monospaced char width
let rowH: CGFloat = fontSize * 1.35          // row spacing
let baseY = h * 0.06                         // top margin
func rowY(_ row: Int) -> CGFloat { baseY + CGFloat(row) * rowH }
```

Characters placed at fractional positions (`w * 0.28`, `w * 0.72`), not strict grid columns. Layout adapts to canvas width while keeping monospaced feel.

## Drawing Primitives

```swift
drawChar(context, "═", at: CGPoint(x, y), size: fontSize, color: wireColor)
drawCharBold(context, "A", at: CGPoint(x, y), size: fontSize, color: labelColor)
drawString(context, "┌───Body───┐", centerX: w * 0.5, y: rowY(9),
           cellW: cellW, fontSize: fontSize, color: bodyColor, bold: true)
```

## Character Palette

**Wiring**: `─ │ ┌ ┐ └ ┘ ┬` (single-line)
**Heavy/resonance**: `═ ║ ╔ ╗ ╚ ╝` (double-line)
**Components**: `╪` (capacitor), `╲ ╱` (diagonal wire), `▼` (output)
**Energy fill**: `░ ▒ ▓ █` (low → max)
**Wave shape**: `△ ◇ ○ □` (tri → square)

## Reactivity Rules

Each synth parameter drives one or more visual properties. The schematic should **look like the circuit feels**.

| Technique | What it does | Example |
|-----------|-------------|---------|
| Char swap | Discrete state change | `░→▓` for energy, `┌→╔` for resonance |
| Opacity ramp | Continuous intensity | `coupleOp = 0.15 + couple * 0.75` |
| Position offset | Physical displacement | `capBYOffset = tune * 4 * cs` |
| Char set upgrade | Mode shift | Single-line → double-line at `body > 0.5` |
| Fill level | Quantity | Bottom-up row fill in beaker visual |

## Animation

- **15fps** via TimelineView — enough for char transitions, not wasteful
- `sin(time * freq)` for smooth oscillation (pulse, wobble, shimmer)
- Threshold comparison against sin for flicker
- Animation is accent, not distraction — only elements representing energy/activity animate

## Shimmer Without Randomness

```swift
let shimmerTick = Int(fmod(time * 8, 1000))
let cellHash = (row * 7 + col + shimmerTick) % 11
let shimmer = cellHash == 0  // ~1 in 11 cells flicker per frame
```

## ASCII Fluid Knobs (Interactive)

Single `Canvas` + `DragGesture` draws all knobs. Knob ID from `startLocation.x / knobW`. Vertical drag = value (150pt = full 0→1 range). Active knob at full opacity, inactive at 0.55.

## Design Process for New Synth Panels

1. Identify the signal flow — what are the conceptual stages?
2. Map to ASCII topology — vertical flow diagram with box-drawing chars
3. Assign characters to components from the palette above
4. Wire each parameter to exactly one visual property
5. Add animation sparingly — only where it represents real energy

## Sizing Rules

- Font: `max(10, 11 * cs)`
- Cell width: `fontSize * 0.62`
- Row height: `fontSize * 1.35`
- Canvas height: `180 * cs` for ~13 rows
- Horizontal positions: fractional `w *`, vertical: `rowY(n)`
