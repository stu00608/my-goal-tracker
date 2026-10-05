import SwiftUI

extension View {
    func statusToast(message: Binding<String?>, identifier: String, autoDismiss: Bool = true) -> some View {
        modifier(StatusToast(message: message, identifier: identifier, autoDismiss: autoDismiss))
    }
}

/// A transient response to an action. It floats over content and never changes its layout.
private struct StatusToast: ViewModifier {
    @Binding var message: String?
    let identifier: String
    let autoDismiss: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var textSize

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill").font(.title3).foregroundStyle(.red).accessibilityHidden(true)
                    Text(message).font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(identifier)
                    Button { self.message = nil } label: {
                        Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel(L.text("Dismiss message"))
                        .accessibilityIdentifier(identifier + ".dismiss")
                }
                .foregroundStyle(Color.primary).padding(16)
                .background {
                    if reduceTransparency { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)) }
                    else { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial) }
                }
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.08)) }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                .frame(maxWidth: 440).padding(.horizontal, 16).padding(.top, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .sensoryFeedback(.error, trigger: message) { _, new in new != nil }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 1), value: message)
        .task(id: message) {
            guard let shown = message else { return }
            UIAccessibility.post(notification: .announcement, argument: shown)
            guard autoDismiss, !UIAccessibility.isVoiceOverRunning, !textSize.isAccessibilitySize else { return }
            do {
                try await Task.sleep(for: .seconds(8))
                try Task.checkCancellation()
                if message == shown { message = nil }
            } catch { }
        }
    }
}
