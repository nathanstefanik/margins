import SwiftUI

/// A bottom-anchored error card for transient failures: warning glyph,
/// the message, tap-to-dismiss. Control-plane chrome — it floats over the
/// content in glass rather than pushing a system alert.
private struct ErrorBannerCard: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.controlInset) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss)
                .font(.subheadline)
        }
        .padding(.horizontal, DesignTokens.Spacing.actions)
        .padding(.vertical, DesignTokens.Spacing.chrome)
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.Radius.card))
        .onTapGesture(perform: dismiss)
        .padding(.horizontal, DesignTokens.Spacing.grid)
        // Floating tab bar height plus its float gap, so the card sits
        // above the bar instead of sliding under it.
        .padding(.bottom, 64)
        .accessibilityElement(children: .contain)
    }
}

/// Overlays `message` as a glass card at the bottom when set. The card
/// dismisses on tap, through the explicit Dismiss button, or after eight
/// seconds — a new message restarts the timer. Under Reduce Motion the
/// card fades in place only.
extension View {
    func errorBanner(_ message: Binding<String?>) -> some View {
        modifier(ErrorBannerOverlay(message: message))
    }
}

private struct ErrorBannerOverlay: ViewModifier {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                ErrorBannerCard(message: message) { self.message = nil }
                    .transition(
                        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
                    )
                    // A new message replaces the card and its clock; the
                    // task-id restarts the eight-second window.
                    .id(message)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(8))
                        if !Task.isCancelled { self.message = nil }
                    }
            }
        }
        .animation(
            reduceMotion ? nil : DesignTokens.Motion.prompt,
            value: message != nil
        )
    }
}
