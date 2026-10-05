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
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 20))
                        .padding(.top, 12).accessibilityHidden(true)
                    Text(message).font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(identifier)
                    Button { self.message = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel(L.text("Dismiss message"))
                        .accessibilityIdentifier(identifier + ".dismiss")
                }
                .foregroundStyle(.primary).padding(.leading, 14).padding(.trailing, 2)
                .background {
                    if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)) }
                    else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) }
                }
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.08)) }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                .frame(maxWidth: 440).padding(.horizontal, 16).padding(.top, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
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
