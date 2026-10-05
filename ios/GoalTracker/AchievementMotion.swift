import SwiftUI
import CoreMotion
import Observation
import UIKit

/// One visible detail card owns one sensor. No motion data leaves this object.
@MainActor @Observable final class AchievementMotion {
    private(set) var x = 0.0
    private(set) var y = 0.0
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private var neutral: (x: Double, y: Double)?

    func start() {
        guard session == nil, manager.isDeviceMotionAvailable else { return }
        let token = UUID()
        session = token
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            let x = max(-1, min(1, gravity.x))
            let y = max(-1, min(1, gravity.z))
            guard x.isFinite, y.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self, self.session == token else { return }
                if self.neutral == nil { self.neutral = (x, y) }
                guard let neutral = self.neutral else { return }
                self.x += (max(-1, min(1, x - neutral.x)) - self.x) * 0.18
                self.y += (max(-1, min(1, y - neutral.y)) - self.y) * 0.18
            }
        }
    }

    func stop() {
        session = nil; neutral = nil
        manager.stopDeviceMotionUpdates()
        x = 0; y = 0
    }

    isolated deinit { manager.stopDeviceMotionUpdates() }
}

/// Shallow relief: <=4 degrees rotation and <=5pt foreground displacement.
/// Export uses AchievementPoster directly, so neither sensor nor drag can affect its pixels.
struct AchievementRelief<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var motion = AchievementMotion()
    @State private var visible = false
    @State private var drag = CGSize.zero
    var sensorEnabled = true
    let content: (CGSize) -> Content

    private var offset: CGSize {
        guard !reduceMotion, scenePhase == .active else { return .zero }
        return CGSize(width: max(-1, min(1, motion.x + drag.width / 100)) * 5,
                      height: max(-1, min(1, motion.y + drag.height / 100)) * 5)
    }

    var body: some View {
        let offset = offset
        content(offset)
            .rotation3DEffect(.degrees(-offset.height * 0.8), axis: (x: 1, y: 0, z: 0), perspective: 0.12)
            .rotation3DEffect(.degrees(offset.width * 0.8), axis: (x: 0, y: 1, z: 0), perspective: 0.12)
            .overlay {
                AchievementDragSurface(translation: $drag, enabled: !reduceMotion && scenePhase == .active)
                    .accessibilityHidden(true)
            }
            .onAppear { visible = true; updateSensor() }
            .onDisappear { visible = false; motion.stop() }
            .onChange(of: scenePhase) { _, _ in updateSensor() }
            .onChange(of: reduceMotion) { _, _ in updateSensor() }
            .onChange(of: sensorEnabled) { _, _ in updateSensor() }
    }

    private func updateSensor() {
        if visible && sensorEnabled && scenePhase == .active && !reduceMotion { motion.start() }
        else { motion.stop() }
    }
}

/// A horizontal start tilts the card; vertical starts stay with the surrounding ScrollView.
/// After recognition, both axes follow the finger. Native failure/coordination preserves scrolling.
private struct AchievementDragSurface: UIViewRepresentable {
    @Binding var translation: CGSize
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.isUserInteractionEnabled = enabled
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: AchievementDragSurface
        init(_ parent: AchievementDragSurface) { self.parent = parent }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard parent.enabled, let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            // Leave the navigation edge to UIKit's interactive back gesture.
            return pan.location(in: pan.view).x > 20 && abs(velocity.x) > abs(velocity.y)
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let value = recognizer.translation(in: recognizer.view)
                parent.translation = CGSize(width: value.x, height: value.y)
            case .ended, .cancelled, .failed:
                withAnimation(.spring(response: 0.4, dampingFraction: 1)) { parent.translation = .zero }
            default: break
            }
        }
    }
}
