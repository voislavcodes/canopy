---
name: design
description: Create a design doc for a new feature or system. Enforces a consistent structure so design docs can be consumed by plan-from-design.
disable-model-invocation: true
argument-hint: [feature name or description]
---

# Design Doc Writer

Create a design document for: **$ARGUMENTS**

If no argument was provided, ask the user what they want to design.

## Process

1. **Research first** — Before writing anything, explore the codebase to understand:
   - What exists today that relates to this feature
   - What data model structures are involved
   - What patterns the codebase already uses
   - What constraints CLAUDE.md imposes (core philosophy, architecture rules)

2. **Ask clarifying questions** if the scope is ambiguous. Better to clarify now than redesign later.

3. **Write the design doc** using the structure below. Save it to a location the user specifies, or suggest a reasonable path (e.g., `docs/design/<feature-name>.md`).

## Design Doc Structure

```markdown
# <Feature Name> — Design Doc

## Problem
What doesn't exist yet, or what's wrong with what exists? 1-3 sentences.

## Approach
High-level strategy. Why this approach over alternatives? What was considered and rejected?

## Data Model
What new types are needed? What existing types change? Show the structs/enums.
If no model changes needed, say so explicitly.

## Signal Flow (if audio-related)
ASCII diagram of the audio signal path. What nodes, what connections, what processing order.

## UI
What the user sees and interacts with. Describe the visual layout and interaction model.
Include ASCII mockups if helpful.

## Implementation Notes
Specific technical details, edge cases, or gotchas. Reference existing patterns in the codebase.

## Open Questions
Anything unresolved that needs decision before implementation.
```

## Rules

- Every section must be present. If a section doesn't apply (e.g., "Signal Flow" for a pure UI feature), write "N/A" with a brief reason.
- Reference existing code by file path when describing what changes.
- If the feature touches audio code, check the dsp-guard skill's rules and flag any potential violations.
- If the feature involves a new synth panel UI, reference the ascii-schematic skill's patterns.
- Keep it concise. A design doc is a decision record, not a novel.
