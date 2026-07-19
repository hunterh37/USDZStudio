import SwiftUI
import DicyaninDesignSystem

/// The guided tour's floating card: step icon, narration, progress dots, and
/// the Next button that drives the live demonstration. Sits bottom-center over
/// the viewport (the hotkey-hint overlay yields while the tour runs).
struct TutorialOverlay: View {

    let engine: TutorialEngine

    var body: some View {
        VStack {
            Spacer()
            card
                .padding(.bottom, Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.35), value: engine.stepIndex)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: engine.currentStep.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accent.color)
                    .frame(width: 26)
                Text(engine.currentStep.title)
                    .font(.system(size: TypeScale.title, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                Spacer(minLength: Spacing.md)
                progressDots
            }

            Text(engine.currentStep.body)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Skip Tour") { engine.skip() }
                    .buttonStyle(.plain)
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.textTertiary.color)
                Spacer()
                Button(action: { engine.next() }) {
                    HStack(spacing: 6) {
                        if engine.isAnimating {
                            ProgressView().controlSize(.small)
                        }
                        Text(engine.isLastStep ? "Start Creating" : "Next")
                            .fontWeight(.semibold)
                        if !engine.isLastStep && !engine.isAnimating {
                            Image(systemName: "arrow.right")
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent.color)
                .disabled(engine.isAnimating)
            }
        }
        .padding(Spacing.md)
        .frame(width: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.panelBorder.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(engine.steps) { step in
                Circle()
                    .fill(step.id <= engine.stepIndex
                        ? Palette.accent.color
                        : Palette.textTertiary.color.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
    }
}
