import SwiftUI

/// The first thing a new user sees.
///
/// Before this existed, launching Tyland fired up to five system alerts demanding Calendar,
/// camera, Bluetooth and audio access from an app with no window, no Dock icon and a blank icon.
/// That reads as spyware, and it is almost certainly the single largest reason someone would ask
/// for their money back.
///
/// Nothing here requests anything on its own. Each capability is explained, and asked for only when
/// the user presses its button — or never, because Skip is a first-class option and the app works
/// without any of them.
struct OnboardingView: View {
    @ObservedObject var settings = Settings.shared
    /// Set by the window controller when the user is done.
    var onFinish: () -> Void

    @State private var statuses: [Permission: Permission.Status] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tyland works with none of these. Turn on what you want — you can change "
                         + "any of it later in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Permission.allCases) { permission in
                        row(permission)
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: refresh)
    }

    private var header: some View {
        VStack(spacing: 12) {
            NotchPreview()
                .frame(width: 240, height: 52)
            Text("Tyland")
                .font(.title2.weight(.semibold))
            Text("A Dynamic Island for your notch — or for any Mac without one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .padding(.horizontal, 22)
    }

    private func row(_ permission: Permission) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.callout.weight(.medium))
                    statusBadge(statuses[permission] ?? .unknown)
                }
                Text(permission.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Needed by: \(permission.neededBy)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            action(for: permission)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func action(for permission: Permission) -> some View {
        switch statuses[permission] ?? .unknown {
        case .notDetermined:
            Button("Allow") {
                permission.request { _ in refresh() }
            }
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Button("Open Settings") { permission.openSettingsPane() }
                .buttonStyle(.link)
        case .unknown:
            // No pre-flight API exists for these; macOS asks the first time the feature runs.
            Text("On first use").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func statusBadge(_ status: Permission.Status) -> some View {
        Group {
            switch status {
            case .granted: Text("Allowed").foregroundStyle(.green)
            case .denied: Text("Denied").foregroundStyle(.orange)
            case .notDetermined: Text("Not asked").foregroundStyle(.secondary)
            case .unknown: EmptyView()
            }
        }
        .font(.caption2.weight(.medium))
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            Spacer()
            Button("Start using Tyland", action: onFinish)
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private func refresh() {
        var next: [Permission: Permission.Status] = [:]
        for permission in Permission.allCases { next[permission] = permission.status }
        statuses = next
    }
}

/// A static drawing of the island, so the first screen shows the thing being described.
private struct NotchPreview: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(
                    colors: [Color(white: 0.30), Color(white: 0.12)],
                    startPoint: .top, endPoint: .bottom
                ))
            NotchShape(topRadius: 8, bottomRadius: 12)
                .fill(.black)
                .frame(width: 128, height: 26)
                .overlay(alignment: .trailing) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .padding(.trailing, 16)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
