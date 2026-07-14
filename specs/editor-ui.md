# EditorUI Specification — Panels & Layout

## Layout (classic 3D editor chrome)

```
┌────────────────────────────────────────────────────────────────┐
│ Toolbar: mode ▸ select/move/rotate/scale │ debug view │ env │ ⌘K│
├──────────┬──────────────────────────────────────┬──────────────┤
│ Outliner │                                      │  Inspector   │
│ (left,   │            Viewport                  │  (right,     │
│ 260pt,   │                                      │  320pt,      │
│ collapsible)                                    │  tabbed)     │
│          │                                      │              │
│ Variants ├──────────────────────────────────────┤              │
│ (sub-    │ Transport bar (when animated)        │              │
│  panel)  │                                      │              │
├──────────┴──────────────────────────────────────┴──────────────┤
│ Drawer (bottom, collapsible tabs): Log │ Python │ Diagnostics  │
├────────────────────────────────────────────────────────────────┤
│ Status bar: sel path │ tris │ units │ validation ●3 ⚠️2 │ zoom  │
└────────────────────────────────────────────────────────────────┘
```

- `NSSplitViewController`-backed (AppKit host) with SwiftUI panel content — gives pro-grade resizable/collapsible splits, full-height sidebars, state restoration.
- Document-based (`.usdz/.usda/.usdc` document types), native tabs, autosave to draft, Versions browser integration.

## Outliner

- Lazy tree over the prim snapshot (handles 10k+ prims: flat-array data source, disclosure state per path).
- Row: type icon (Xform/Mesh/Material/Camera/Light/Scope/Skeleton) · name · badges (variant, reference arrow, "unsupported-in-viewport") · visibility eye · enable/disable toggle · lock.
- Eye toggle = `visibility` (hidden but ships in file); enable toggle = `active` (excluded from export); disabled rows render dimmed with strikethrough-style deemphasis. Tooltip on each explains the semantic — this distinction is a top user-confusion risk, so the UI over-communicates it.
- Search field with type filters; ⌘F focuses. Context menu: rename, duplicate, delete, group in Xform, copy prim path, isolate.
- Drag to reparent (emits `ReparentCommand`). Multi-select syncs with viewport.
- Separate collapsible sections: **Scene**, **Materials** (flat list of all Material prims), **Variants** (variant sets on selection with radio switching).

## Inspector (right panel, context-sensitive tabs)

Tabs appear per selection type via `InspectorPanelProvider` registry:

1. **Transform** — TRS numeric fields (draggable-label scrubbing), pivot info, world/local readout, reset buttons.
2. **Prim** — type, kind, purpose, active/instanceable toggles, applied schemas list, custom metadata key-value editor.
3. **Material** (Material prim or bound-material shortcut on mesh) — every UsdPreviewSurface input as the right control: color wells, sliders (0–1), texture slots with 64pt previews, "reveal texture", replace/resize/re-encode actions, st/UV transform.
4. **Geometry** (Mesh) — counts, subdivision scheme, normals source, extent, bound material with "go to" link.
5. **Stage** (no selection) — upAxis, metersPerUnit, defaultPrim picker, startTime/endTime, layer stack list, customLayerData editor, file-size breakdown pie (geometry/textures/other).
6. **Physics** (stretch, visionOS preset) — collision, mass on RigidBody-schema prims.

All numeric fields commit through EditingKit commands → undoable, scrub-friendly (one undo group per scrub).

## Command Palette (⌘K)

- Fuzzy-matched actions (every menu item auto-registered), prim search ("go to prim"), preset application, script invocation. Recent-weighted. This is the enterprise-power feature: everything reachable without a mouse.

## Drawer

- **Log:** structured OSLog stream, filter by category/severity, copy as text.
- **Python:** REPL (see scripting spec).
- **Diagnostics:** live ValidationKit results table; row click selects offending prim; quick-fix buttons where rules provide them.

## Menus & Shortcuts (excerpt)

| Action | Shortcut |
|---|---|
| Frame selection / all | F / A |
| Select–Move–Rotate–Scale | Q W E R |
| Duplicate prim | ⌘D |
| Group in Xform | ⌘G |
| Toggle outliner / inspector / drawer | ⌘⌥1 / ⌘⌥2 / ⌘⌥3 |
| Command palette | ⌘K |
| Export USDZ… | ⌘⇧E |
| Validate | ⌘⇧V |

## State & Persistence

- Panel widths, drawer state, view mode, environment choice persisted per-document (`customLayerData` under `dicyanin:` namespace, opt-out) and app-wide defaults.
