import SwiftUI

/// Permission-request state only. HealthKit never exposes whether reading was granted.
struct HealthConnectionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    let keys: Set<HealthFactKey>
    let onFailure: (String) -> Void
    @State private var setup = HealthAccessSetup.checking
    @State private var connecting = false
    @State private var guidance = false
    @State private var request: Task<Void, Never>?
    private var signature: String { keys.map { $0.metric.rawValue }.sorted().joined(separator: ",") + String(describing: scenePhase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(L.text("Apple Health"), systemImage: "heart.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if setup == .requested {
                    Button { guidance = true } label: { Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless).accessibilityLabel(L.text("Manage health access"))
                        .accessibilityIdentifier("health.manage")
                }
            }
            switch setup {
            case .checking: ProgressView(L.text("Checking health access…"))
            case .requestNeeded:
                Text(L.text("Connect to use the health data selected for your conditions. Only the selected types are requested."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(L.text("Connect Apple Health"), action: connect)
                    .buttonStyle(.borderless).disabled(connecting).frame(minHeight: 44)
                    .accessibilityIdentifier("health.connect")
                if connecting { ProgressView() }
            case .requested:
                Label(L.text("Automatically reads available data"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("health.configured")
            case .unavailable:
                Text(L.text("Apple Health is unavailable on this device.")).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .task(id: signature) {
            guard scenePhase == .active else { return }
            do { setup = try await HealthConditions.shared.setup(keys: keys) }
            catch is CancellationError { }
            catch { setup = .requestNeeded; onFailure(L.error(error)) }
        }
        .onDisappear { request?.cancel() }
        .sheet(isPresented: $guidance) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(L.text("Apple Health"), systemImage: "heart.fill").font(.title2.weight(.semibold))
                        Text(L.text("In Apple Health, tap your profile, then Apps and Goalooker to review steps and sleep read access."))
                        Text(L.text("No readable samples can mean there is no data yet or read access is off. Apple Health keeps these cases private; Goalooker never assumes zero."))
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.navigationTitle(L.text("Manage health access")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L.text("Done")) { guidance = false } } }
            }.presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large]).presentationDragIndicator(.visible)
        }
    }
    private func connect() {
        guard !connecting else { return }; connecting = true
        request = Task {
            defer { connecting = false }
            do {
                try await HealthConditions.shared.connect(keys: keys)
                try Task.checkCancellation()
                setup = try await HealthConditions.shared.setup(keys: keys)
            } catch is CancellationError { }
            catch { setup = .requestNeeded; onFailure(L.error(error)) }
        }
    }
}
