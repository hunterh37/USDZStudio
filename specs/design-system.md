# DicyaninDesignSystem Specification

## Design Direction

**Enterprise-restrained, dense, calm.** The reference class is pro tools users trust with production assets: Xcode's inspector density, Nova's polish, Blackmagic Resolve's dark neutrality — not consumer-app playfulness. The viewport is the hero; chrome recedes.

## Foundations

### Color (dark theme default; light theme supported via semantic tokens)

| Token | Dark value | Use |
|---|---|---|
| `surface.base` | #1C1C1E | window background |
| `surface.panel` | #232326 | outliner/inspector panels |
| `surface.raised` | #2C2C30 | cards, popovers, fields |
| `surface.viewport` | #161618 | viewport gutter |
| `stroke.subtle` / `stroke.strong` | #FFFFFF @ 8% / 16% | separators, field borders |
| `text.primary` / `secondary` / `tertiary` | 92% / 60% / 38% white | |
| `accent` | #5E8BFF (desaturated blue) | selection, focus, primary buttons |
| `signal.error` / `warning` / `ok` | #FF5D5D / #FFB84D / #4DC98A | diagnostics only — never decorative |

Rules: color communicates state, never decoration. One accent. No gradients except viewport environment previews. Selection in outliner/viewport share the accent for cross-panel scannability.

### Typography

- SF Pro Text throughout; SF Mono for prim paths, attribute names, console, numeric fields.
- Scale: 11pt panel body (dense pro default), 10pt secondary/labels, 13pt panel titles, 11pt mono values.
- Numerals: monospaced digits everywhere numbers can change (no layout jitter while scrubbing).

### Spacing & Metrics

- 4pt base grid. Inspector row height 24pt, outliner row 22pt, toolbar 38pt.
- Panel padding 12pt; control corner radius 5pt; panels 0 radius (edge-to-edge splits).

## Component Library (SwiftUI, in `DicyaninDesignSystem`)

- `DSNumericField` — scrubbable label (drag to adjust), unit suffix, expression evaluation (`2+0.5` allowed), commit-on-release semantics for undo coalescing.
- `DSVectorField` — 3× numeric with axis color chips (X #E0685E, Y #7CBF5E, Z #5E8BFF — the one place per-axis color is allowed).
- `DSSlider` — compact slider + numeric combo for 0–1 material params.
- `DSColorWell`, `DSTextureSlot` (64pt preview, drop target, context actions).
- `DSInspectorSection` — collapsible, persisted disclosure state.
- `DSTreeRow`, `DSBadge`, `DSSeverityIcon`, `DSToolbarSegment`, `DSSearchField`.
- `DSTable` — diagnostics/batch tables (NSTableView-backed for perf).
- `DSEmptyState` — instructive empty panels ("No selection — click a prim in the viewport").

Every component gets a preview catalog target (in-app debug gallery, doubles as visual regression snapshot source).

## Interaction Standards

- Every action: menu item + shortcut + command palette entry (enforced by registering actions once in an `ActionRegistry` that feeds all three).
- Hover reveals affordances (row action buttons) — default state stays quiet.
- Progressive disclosure: advanced options behind disclosure, never removed.
- Full keyboard navigation and VoiceOver labels on custom controls; contrast AA minimum on all text tokens.

## Voice & Copy

- Sentence case everywhere. Terse, specific: "3 textures exceed 2048 px" not "Some textures may be too large!". Diagnostics always name the prim and the fix.
