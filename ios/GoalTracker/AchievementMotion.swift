import SwiftUI
import CoreMotion
import Observation

/// One visible detail card owns one sensor. No motion data leaves this object.
@MainActor @Observable final class AchievementMotion {
    private(set) var x = 0.0
    private(set) var y = 0.0
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var session: UUID?

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
                self.x += (x - self.x) * 0.18
                self.y += (y - self.y) * 0.18
            }
        }
    }

    func stop() {
        session = nil
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
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.4, dampingFraction: 1)))
    private var drag = CGSize.zero
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
            .simultaneousGesture(DragGesture(minimumDistance: 10).updating($drag) { value, state, _ in
                if !reduceMotion { state = value.translation }
            })
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
