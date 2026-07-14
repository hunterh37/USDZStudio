# ValidationKit Specification

## Purpose

Answer the question every AR developer has: **"Will this USDZ actually work where I'm shipping it?"** Two layers: spec-level compliance (delegated to Pixar's ComplianceChecker via the bridge) and target-profile rules (our own Swift rule engine).

## Rule Engine

```swift
public protocol ValidationRule {
    var id: String { get }                   // "texture.max-size"
    var title: String { get }
    var severity: DiagnosticSeverity { get } // error / warning / info
    var profiles: Set<TargetProfile> { get } // .quickLook, .realityKitIOS, .visionOS, .generic
    func evaluate(stage: USDStageProtocol) -> [Diagnostic]
}

public struct Diagnostic {
    public let ruleID: String
    public let message: String
    public let primPath: PrimPath?
    public let severity: DiagnosticSeverity
    public let quickFix: EditCommand?        // optional one-click fix
}
```

Profiles selected in a toolbar picker; diagnostics update live (debounced) as the user edits.

**Default profile is `.realityKitIOS` + `.quickLook` combined** — every document is validated against "will this render correctly in a RealityKit app?" from the moment it opens. The `.generic` profile exists for USD-pipeline users but is opt-in. Anything in the stage that RealityKit cannot render (non-PreviewSurface shader networks, unsupported schemas) is a standing warning with a conversion quick-fix where feasible (e.g. "Bake MaterialX to PreviewSurface approximation") — the app actively pushes files *toward* RealityKit compatibility, not just reports on it.

## v1 Rule Catalog (target profiles)

| Rule | Profile | Severity | Quick-fix |
|---|---|---|---|
| Texture exceeds 2048² (QuickLook perf guidance) | quickLook | warning | Resize |
| Non-power-of-two texture | quickLook | info | Resize |
| Texture memory > 200MB estimated | all | warning | Batch resize |
| Triangle count > 500k | quickLook | warning | — (suggest decimation script) |
| metersPerUnit ≠ 1 | quickLook | warning | Rescale |
| upAxis ≠ Y | quickLook/RealityKit | error | Convert |
| No defaultPrim set | all | error | Set to root |
| Prim names with illegal/duplicate identifiers | all | error | Sanitize |
| Unbound meshes (no material) | all | info | Assign default |
| Non-PreviewSurface shader networks | quickLook | warning | — |
| Opacity + doubleSided combination pitfalls | quickLook | info | — |
| Missing/oversized velocity of file (>25MB warning for web AR) | ecommerce | warning | — |
| Skeleton bound outside SkelRoot | RealityKit | error | Wrap in SkelRoot |
| Animation exceeds timeCode metadata range | all | warning | Fix range |

## ComplianceChecker Integration

- `UsdUtils.ComplianceChecker` (ARKit-compat flag on) run via bridge on demand (⌘⇧V) and before every export; results merged into the same Diagnostics table with rule ID prefix `pixar.`.

## UI

- Status bar shows live counts (● errors, ⚠ warnings); click opens Diagnostics drawer tab.
- Table rows: severity icon, rule, message, prim link (click = select + frame), quick-fix button.
- Export sheet blocks on errors (overridable with an explicit "Export anyway" for power users), lists warnings.
- Batch reports include full diagnostics per file.

## Extension

Rules are registered via a `ValidationRuleRegistry`; adding a rule = one file + one registration line + one test. Community rule contributions are an explicit goal — first-issue friendly.
