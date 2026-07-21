# Command Palette & ActionRegistry

Contract for the ⌘K command palette and the action model that unifies the
menu bar, keyboard shortcuts, and the palette. Goal: **one command has exactly
one behaviour**, regardless of how it is invoked. (ROADMAP Phase 5 / Continuous
— "menu/shortcut/palette unification".)

## Layering

Pure, UI-free, 100%-covered (in `EditorUI`, alongside the panels they back):

- **`ActionItem`** — a `Sendable` value describing a command: stable `id`,
  `title`, `category`, optional `shortcut` display string, extra `keywords`, and
  `isEnabled`. No closure — behaviour is bound separately so the descriptor stays
  a pure value the registry can rank off the main actor.
- **`FuzzyMatcher.score(query:in:)`** — deterministic, case-insensitive
  subsequence match returning a score or `nil`. Bonuses: +5 at a word boundary
  (index 0, after a `space`/`-`/`_`/`/`, or a camelCase hump), +3 for a run of
  consecutive matches, +2 at the very start. Empty query trivially matches (0).
- **`ActionRegistry.search(_:)`** — ranks items for a query. Title is weighted
  above keywords/category. Ordering is a **total order** — enabled-first, then
  higher score, then title — so results are deterministic even on ties. An empty
  query returns every item in a stable default order (enabled, category, title).

Main-actor view state, unit-tested directly (`CommandPaletteModelTests`):

- **`PaletteAction`** — pairs an `ActionItem` with its `@MainActor` run closure.
- **`CommandPaletteModel`** (`@Observable @MainActor`) — holds `query`, ranked
  `results`, and `selectedIndex`; re-ranks and re-clamps on every change.
  `moveUp`/`moveDown` are bounded; `runSelected()` invokes the highlighted
  action **only when enabled** and reports whether it ran.

Thin SwiftUI (`CommandPaletteView` + `CommandPaletteBackdrop`, tracked by the
Phase T1 snapshot-UI harness): a focused search field over the ranked list;
↑/↓ navigate, ↩ runs (and dismisses only on a successful run), ⎋ or a backdrop
click dismisses. Disabled rows render greyed but are never runnable.

## Wiring

The shell (`EditorShellView`) builds the action set against **live context** each
time the palette opens (`paletteActions()`), so `isEnabled` matches the menu's
own enablement. Every entry routes to the same code path as its menu/toolbar
twin — sheets via `activeSheet`, document ops via `EditorDocument`, and the
File actions (Open/Save/Save As) via app-supplied closures. ⌘K opens the palette
(the App menu carries the same "Command Palette…" item); Convert File moved from
⌘K to ⇧⌘K to free the accelerator.

## Invariants

- Ranking is deterministic and total (same input → same order; no ties left to
  chance). Verified by permutation-invariance tests.
- A palette action never introduces a second behaviour for a command — it
  invokes the existing seam. Adding a command means adding one `PaletteAction`
  next to its menu definition.
- Disabled actions are visible but inert.
