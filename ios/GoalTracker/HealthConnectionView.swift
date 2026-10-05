import SwiftUI

/// The shared settings sheet manages the authorization request, not a claim of read access.
struct HealthSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var setup = HealthAccessSetup.checking
    @State private var connecting = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "heart.fill").font(.system(size: 44)).foregroundStyle(.pink).accessibilityHidden(true)
                    Text(L.text("Use steps and sleep to check your goal conditions."))
                        .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(L.text("Goalooker only reads health data. It never writes to Apple Health."))
                        .foregroundStyle(.secondary)
                    switch setup {
                    case .checking:
                        ProgressView().accessibilityLabel(L.text("Checking health access…"))
                    case .requestNeeded:
                        connectButton
                    case .requested:
                        Text(L.text("In Apple Health, tap your profile, then Apps and Goalooker to review steps and sleep read access."))
                            .accessibilityIdentifier("health.accessGuidance")
                    case .unavailable:
                        Text(L.text("Apple Health is unavailable on this device.")).foregroundStyle(.secondary)
                    }
                    Text(L.text("No readable samples can mean there is no data yet or read access is off. Apple Health keeps these cases private; Goalooker never assumes zero."))
                        .font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            .statusToast(message: $error, identifier: "health.error")
            .navigationTitle(L.text("Apple Health")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text(L.text("Done")).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("health.done")
                }
            }
            .task(id: String(describing: scenePhase) + String(HealthConditions.shared.revision)) {
                guard scenePhase == .active else { return }
                do { setup = try await HealthConditions.shared.setup(keys: HealthConditions.supportedKeys) }
                catch is CancellationError { }
                catch { setup = .requestNeeded; self.error = L.error(error) }
            }
            .onDisappear { request?.cancel() }
        }
        .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private var connectButton: some View {
        Button(action: connect) {
            HStack {
                Spacer(minLength: 0)
                if connecting { ProgressView().tint(Color.white) }
                Text(L.text("Connect Apple Health")).fontWeight(.semibold)
                Spacer(minLength: 0)
            }.padding(.vertical, 8)
        }.buttonStyle(.borderedProminent).tint(.pink).disabled(connecting)
            .accessibilityIdentifier("health.connect")
    }
    private func connect() {
        guard !connecting else { return }
        connecting = true
        request = Task {
            defer { connecting = false }
            do {
                try await HealthConditions.shared.connect(keys: HealthConditions.supportedKeys)
                try Task.checkCancellation()
                setup = try await HealthConditions.shared.setup(keys: HealthConditions.supportedKeys)
                if setup == .requested { dismiss() }
            } catch is CancellationError { }
            catch { self.error = L.error(error) }
        }
    }
}
