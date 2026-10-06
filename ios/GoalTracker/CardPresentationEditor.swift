import SwiftUI

/// Form rows only. The integration owner supplies the surrounding Section and draft bindings.
struct CardPresentationEditor: View {
    @Binding var textPosition: CardTextPosition
    @Binding var showLastRecorded: Bool
    @Binding var ringStyle: RingProgressStyle
    let background: CardBackground
    private var showsRing: Bool { background == .progress }

    var body: some View {
        if !showsRing {
            Picker(L.text("Card text position"), selection: Binding(get: { textPosition.resolved(for: background) }, set: { textPosition = $0 })) {
                ForEach(CardTextPosition.available(for: background), id: \.self) { position in
                    Text(L.text(position.labelKey)).tag(position)
                }
            }
            .tint(.primary).accessibilityIdentifier("card.textPosition")
        }
        Toggle(L.text("Show last recorded date"), isOn: $showLastRecorded)
            .accessibilityIdentifier("card.showLastRecorded")
        if showsRing {
            Picker(L.text("Ring value"), selection: $ringStyle) {
                Text(L.text("Percentage")).tag(RingProgressStyle.percent)
                Text(L.text("Current / target")).tag(RingProgressStyle.fraction)
            }
            .tint(.primary).accessibilityIdentifier("card.ringStyle")
        }
    }
}

private extension CardTextPosition {
    var labelKey: String {
        switch self {
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        case .hidden: "Hidden"
        }
    }
}
