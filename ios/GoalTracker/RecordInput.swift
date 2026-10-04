import SwiftUI
import UIKit

struct DraftPhoto: Identifiable {
    let id = UUID()
    let data: Data
}

/// The display owns scrubbing; the replacement TextField owns all text gestures.
struct NumericValueEditor: View {
    @Binding var text: String
    let precision: Int
    let unit: String
    let isChange: Bool
    let focus: FocusState<Bool>.Binding
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing = false
    @State private var origin: String?
    @State private var lastStep = 0
    @State private var adjustmentError: String?
    private var fieldID: String { isChange ? "entry.change" : "entry.value" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.text(isChange ? "Change amount" : "New value"))
                .font(.subheadline.weight(.medium)).foregroundStyle(TrackerColors.secondaryText)
                .accessibilityIdentifier("entry.value.kind")
            Group {
                if editing {
                    TextField(L.text(isChange ? "Change amount" : "Value"), text: $text)
                        .keyboardType(.decimalPad).focused(focus)
                        .onAppear { focus.wrappedValue = true }
                        .frame(minHeight: 96)
                        .accessibilityIdentifier(fieldID)
                } else {
                    Text(displayValue).foregroundStyle(text.isEmpty ? TrackerColors.secondaryText : Color.primary)
                        .lineLimit(1).minimumScaleFactor(0.2)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                        .contentShape(Rectangle())
                        .overlay {
                            ValueGestureSurface(onTap: { editing = true }, onBegin: {
                                origin = text; lastStep = 0; adjustmentError = nil
                            }, onMove: scrub, onEnd: { origin = nil }, onCancel: restore)
                                .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L.text(isChange ? "Change amount" : "Value"))
                        .accessibilityValue(text.isEmpty ? L.text("Not entered") : displayValue)
                        .accessibilityHint(L.text("Swipe up or down to adjust. Double-tap to type."))
                        .accessibilityIdentifier(fieldID + ".scrubber")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { editing = true }
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: adjust(steps: 1)
                            case .decrement: adjust(steps: -1)
                            @unknown default: break
                            }
                        }
                }
            }
            .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            if !unit.isEmpty { Text(unit).font(.subheadline).foregroundStyle(TrackerColors.secondaryText).fixedSize(horizontal: false, vertical: true) }
            if let adjustmentError { Text(adjustmentError).font(.caption).foregroundStyle(.red) }
            Text(L.text("Slide vertically to adjust · Tap to type"))
                .font(.caption).foregroundStyle(TrackerColors.secondaryText)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(TrackerColors.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
        .onChange(of: scenePhase) { _, phase in if phase != .active { restore() } }
        .onChange(of: focus.wrappedValue) { _, focused in if !focused { editing = false } }
        .onChange(of: isChange) { _, _ in editing = false; focus.wrappedValue = false; restore(); adjustmentError = nil }
    }

    private var displayValue: String {
        if text.isEmpty { return "—" }
        if isChange, !text.hasPrefix("-"), !text.hasPrefix("+") { return "+" + text }
        return text
    }
    private func scrub(_ translation: CGFloat) {
        guard let origin, let steps = NumericEntry.scrubSteps(translation: Double(translation)), steps != lastStep else { return }
        do {
            text = try NumericEntry.adjust(origin, precision: precision, steps: steps, locale: L.locale)
            lastStep = steps; adjustmentError = nil
        } catch { lastStep = steps; adjustmentError = L.error(error) }
    }
    private func restore() {
        if let origin { text = origin }
        origin = nil; lastStep = 0; adjustmentError = nil
    }
    private func adjust(steps: Int) {
        do { text = try NumericEntry.adjust(text, precision: precision, steps: steps, locale: L.locale); adjustmentError = nil }
        catch { adjustmentError = L.error(error) }
    }
}

/// A child photo presentation hides the editor but does not dismiss its controller.
/// Observe dismissal on this editor's controller ancestry, not a generic onDisappear.
struct EditorDismissalObserver: UIViewControllerRepresentable {
    let onDismiss: () -> Void
    func makeUIViewController(context: Context) -> Observer { Observer(onDismiss: onDismiss) }
    func updateUIViewController(_ controller: Observer, context: Context) { controller.onDismiss = onDismiss }

    final class Observer: UIViewController {
        var onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            var ancestor: UIViewController? = self
            while let current = ancestor {
                if current.isBeingDismissed { onDismiss(); return }
                ancestor = current.parent
            }
        }
    }
}

private struct ValueGestureSurface: UIViewRepresentable {
    var onTap: () -> Void
    var onBegin: () -> Void
    var onMove: (CGFloat) -> Void
    var onEnd: () -> Void
    var onCancel: () -> Void
    func makeUIView(context: Context) -> Surface { Surface(callbacks: self) }
    func updateUIView(_ view: Surface, context: Context) { view.callbacks = self }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.cancel() }

    // UIPanGestureRecognizer subtracts its recognition threshold from translation.
    // Keep the initial touch in window coordinates so each 12pt tick uses total travel.
    private final class FullDistancePan: UIPanGestureRecognizer {
        private var start: CGPoint?
        var verticalDistance: CGFloat? {
            start.map { location(in: nil).y - $0.y }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if start == nil { start = touches.first?.location(in: nil) }
            super.touchesBegan(touches, with: event)
        }
        override func reset() { super.reset(); start = nil }
    }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        var callbacks: ValueGestureSurface
        private var active = false
        init(callbacks: ValueGestureSurface) {
            self.callbacks = callbacks
            super.init(frame: .zero)
            let pan = FullDistancePan(target: self, action: #selector(panned))
            pan.maximumNumberOfTouches = 1; pan.delegate = self
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.require(toFail: pan)
            addGestureRecognizer(pan); addGestureRecognizer(tap)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func tapped() { callbacks.onTap() }
        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            let distance = (pan as? FullDistancePan)?.verticalDistance ?? pan.translation(in: self).y
            switch pan.state {
            case .began: active = true; callbacks.onBegin(); callbacks.onMove(distance)
            case .changed: callbacks.onMove(distance)
            case .ended: callbacks.onMove(distance); active = false; callbacks.onEnd()
            case .cancelled, .failed: cancel()
            default: break
            }
        }
        func cancel() { if active { active = false; callbacks.onCancel() } }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: self)
            return abs(velocity.y) >= abs(velocity.x)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

/// A non-cancelling observer on this editor's hosting view, never the app window.
/// Native text inputs retain focus, selection, paste and their own gestures.
final class EditorKeyboardControl {
    weak var host: UIView?
    func dismiss() { host?.endEditing(true) }
}

struct EditorKeyboardDismissal: UIViewRepresentable {
    let keyboard: EditorKeyboardControl
    let dismiss: () -> Void
    func makeUIView(context: Context) -> Observer { Observer(keyboard: keyboard, dismiss: dismiss) }
    func updateUIView(_ view: Observer, context: Context) { view.dismiss = dismiss }
    static func dismantleUIView(_ view: Observer, coordinator: ()) { view.detach() }

    final class Observer: UIView, UIGestureRecognizerDelegate {
        let keyboard: EditorKeyboardControl
        var dismiss: () -> Void
        private weak var host: UIView?
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        init(keyboard: EditorKeyboardControl, dismiss: @escaping () -> Void) { self.keyboard = keyboard; self.dismiss = dismiss; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    host = controller.view; keyboard.host = controller.view; tap.delegate = self; tap.cancelsTouchesInView = false
                    controller.view.addGestureRecognizer(tap); break
                }
                responder = current.next
            }
        }
        func detach() {
            host?.removeGestureRecognizer(tap)
            if keyboard.host === host { keyboard.host = nil }
            host = nil
        }
        @objc private func tapped() { keyboard.dismiss(); dismiss() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UIInputView || current is ValueGestureSurface.Surface { return false }
                view = current.superview
            }
            if let host, containsInput(at: touch.location(in: host), in: host) { return false }
            return true
        }
        private func containsInput(at point: CGPoint, in view: UIView) -> Bool {
            guard !view.isHidden, view.alpha > 0, view.bounds.contains(point) else { return false }
            if view is UITextField || view is UITextView || view is ValueGestureSurface.Surface { return true }
            return view.subviews.contains { containsInput(at: view.convert(point, to: $0), in: $0) }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
