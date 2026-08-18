import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var license = License.shared
    let geometry: NotchGeometry

    @State private var licenseKey = ""
    @State private var licenseError: String?
    @State private var activating = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            widgets.tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
            gestures.tabItem { Label("Gestures", systemImage: "hand.draw") }
            sounds.tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
            notch.tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            licenseTab.tabItem { Label("License", systemImage: "key") }
        }
        .frame(width: 460, height: 470)
    }

    // MARK: - License

    private var licenseTab: some View {
        Form {
            Section {
                LabeledContent("Status") { Text(statusText).foregroundStyle(.secondary) }
                if License.bypassGate {
                    Text("This build has the paywall switched off — every feature is unlocked "
                         + "regardless of licence state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Licence key") {
                TextField("TYLAND-…", text: $licenseKey, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(.caption, design: .monospaced))
                if let licenseError {
                    Text(licenseError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button(activating ? "Activating…" : "Activate") {
                        activating = true
                        Task {
                            licenseError = await license.activate(licenseKey)
                            if licenseError == nil { licenseKey = "" }
                            activating = false
                        }
                    }
                    .disabled(activating
                              || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if case .licensed = license.tier {
                        Button("Remove from this Mac") {
                            license.deactivate()
                            licenseError = nil
                        }
                    }
                }
            }

            Section("What Pro adds") {
                proRow("Every display", "External monitors, all-displays mode — and therefore any "
                       + "Mac with no built-in display.")
                proRow("Live audio waveform", "A real CoreAudio tap, not an animation.")
                proRow("Calendar and leave-in time", "Upcoming events, and MapKit travel time to "
                       + "the next one with an address.")
                proRow("Lock screen widgets", "Experimental.")
                proRow("Extra download folders", "Beyond ~/Downloads.")
            }

            Section {
                Text("Everything else — Now Playing, every HUD, device battery, Focus and recording "
                     + "indicators, gestures and sounds — is free forever, with no time limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch license.tier {
        case .trial(let days):
            return "Trial — \(days) day\(days == 1 ? "" : "s") left"
        case .licensed(let email, let seats):
            return email.isEmpty ? "Licensed" : "Licensed to \(email) (\(seats) devices)"
        case .expired:
            return "Licence needs refreshing — connect to the internet"
        case .free:
            return "Free"
        }
    }

    private func proRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: license.isPro ? "checkmark.circle.fill" : "lock.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(license.isPro ? Color.accentColor : .secondary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Toggle("Expand on hover", isOn: $settings.expandOnHover)
                if settings.expandOnHover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $settings.hoverDuration, in: 0...1, step: 0.05)
                            Text(settings.hoverDuration == 0
                                 ? "Instant"
                                 : String(format: "%.2fs", settings.hoverDuration))
                                .monospacedDigit()
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                }
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section {
                Toggle("Hide while in full screen", isOn: $settings.hideWhileInFullscreen)
                Toggle("Hide from screen capture", isOn: $settings.hideFromScreenCapture)
                Toggle("Hide menu bar icon", isOn: $settings.hideMenuBarIcon)
                if settings.hideMenuBarIcon {
                    Text("With the icon hidden, re-open Settings from Terminal:\n"
                         + App.defaultsCommand("hideMenuBarIcon", "-bool NO"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Picker("Show on", selection: $settings.showOnDisplay) {
                    Text("Built-in display").tag("builtInDisplay")
                    Text("Active display").tag("activeDisplay")
                    Text("All displays").tag("allDisplays")
                }
                Text(displayHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version") {
                    Text("\(App.version) (\(App.build))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var displayHint: String {
        switch settings.showOnDisplay {
        case "activeDisplay":
            return "The island follows the display your pointer is on."
        case "allDisplays":
            return "An island on every screen, each sized to that screen. "
                + "This is the only way to use Tyland on a Mac with no built-in display."
        default:
            return "The island stays on the built-in display, notch or not."
        }
    }

    // MARK: - Widgets

    private var widgets: some View {
        Form {
            Section("Music") {
                Toggle("Now Playing", isOn: $settings.showNowPlaying)
                Picker("Source", selection: $settings.musicApp) {
                    Text("System (any player)").tag("system")
                    Text("Apple Music").tag("music")
                    Text("Spotify").tag("spotify")
                }
                .disabled(!settings.showNowPlaying)
                Toggle("Live waveform", isOn: $settings.showWaveform)
                    .disabled(!settings.showNowPlaying)
            }

            Section("Show in the island") {
                Toggle("Battery and charging", isOn: $settings.showBattery)
                Toggle("Bluetooth devices", isOn: $settings.showBluetooth)
                Toggle("Focus", isOn: $settings.showFocus)
                Toggle("Camera, mic and screen recording", isOn: $settings.showRecording)
                Toggle("Downloads", isOn: $settings.showDownloads)
                Toggle("Calendar", isOn: $settings.showCalendar)
                Toggle("Leave-in time for events", isOn: $settings.showRoute)
                    .disabled(!settings.showCalendar)
                Toggle("Particle effects", isOn: $settings.showParticles)
            }

            Section("Battery") {
                stepperRow("Warn below", value: $settings.lowBatteryThreshold,
                           range: 5...50, step: 5, suffix: "%")
                Toggle("Warn on low device battery", isOn: $settings.warnOnLowConnectBattery)
                    .disabled(!settings.showBluetooth)
                if settings.warnOnLowConnectBattery {
                    stepperRow("Device warns below", value: $settings.deviceLowBatteryThreshold,
                               range: 5...50, step: 5, suffix: "%")
                        .disabled(!settings.showBluetooth)
                }
            }

            Section("Calendar") {
                stepperRow("Look ahead", value: $settings.calendarLookaheadHours,
                           range: 1...72, step: 1, suffix: "h")
                stepperRow("Show at most", value: $settings.calendarEventLimit,
                           range: 1...10, step: 1, suffix: " events")
            }
            .disabled(!settings.showCalendar)

            Section("Leave-in time") {
                Picker("Travel by", selection: $settings.routeTransportType) {
                    Text("Driving").tag("automobile")
                    Text("Walking").tag("walking")
                    Text("Transit").tag("transit")
                }
                stepperRow("Add buffer", value: $settings.routeBufferMinutes,
                           range: 0...60, step: 5, suffix: " min")
                stepperRow("Urgent below", value: $settings.routeUrgentMinutes,
                           range: 1...60, step: 1, suffix: " min")
            }
            .disabled(!settings.showRoute || !settings.showCalendar)
        }
        .formStyle(.grouped)
    }

    // MARK: - Gestures

    private var gestures: some View {
        Form {
            Section {
                Toggle("Natural swipe direction", isOn: $settings.naturalMovement)
                Toggle("Tint with accent colour", isOn: $settings.useAccentColorOnGestures)
            } footer: {
                Text("Two fingers on the island: swipe down to open, up to close, "
                     + "left and right to change track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sensitivity") {
                LabeledContent("Swipe distance") {
                    HStack {
                        Slider(value: $settings.gestureThreshold, in: 6...48, step: 1)
                        Text("\(Int(settings.gestureThreshold)) pt")
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                LabeledContent("Cooldown") {
                    HStack {
                        Slider(value: $settings.gestureCooldown, in: 0.1...1.5, step: 0.05)
                        Text(String(format: "%.2fs", settings.gestureCooldown))
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            }

            Section("How long HUDs stay") {
                LabeledContent("Volume and brightness") {
                    HStack {
                        Slider(value: $settings.hudDismissDelay, in: 0.5...5, step: 0.1)
                        Text(String(format: "%.1fs", settings.hudDismissDelay))
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                LabeledContent("Charging") {
                    HStack {
                        Slider(value: $settings.powerDismissDelay, in: 1...10, step: 0.5)
                        Text(String(format: "%.1fs", settings.powerDismissDelay))
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                LabeledContent("Devices") {
                    HStack {
                        Slider(value: $settings.deviceDismissDelay, in: 1...10, step: 0.5)
                        Text(String(format: "%.1fs", settings.deviceDismissDelay))
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sounds

    private var sounds: some View {
        Form {
            Section {
                Toggle("Sound effects", isOn: $settings.soundsEnabled)
                Picker("Style", selection: $settings.soundTheme) {
                    Text("Synthesised").tag(SoundTheme.synth.rawValue)
                    Text("macOS system sounds").tag(SoundTheme.system.rawValue)
                    Text("Silent").tag(SoundTheme.off.rawValue)
                }
                .disabled(!settings.soundsEnabled)

                LabeledContent("Volume") {
                    Slider(value: $settings.soundVolume, in: 0...1)
                        .disabled(!settings.soundsEnabled)
                }
            }
            Section {
                Text("Synthesised cues are generated at runtime — no audio files are bundled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notch

    private var notch: some View {
        Form {
            Section {
                LabeledContent("Detected") {
                    Text(geometry.isPhysical ? "Physical notch" : "Synthetic (no notch on this Mac)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Size") {
                    Text("\(Int(geometry.collapsedSize.width)) × \(Int(geometry.collapsedSize.height)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // Real notches vary by model and scaling; synthetic ones are a guess. Both need a knob.
            Section("Calibration") {
                VStack(alignment: .leading) {
                    Text("Width \(settings.notchAdjustedWidth >= 0 ? "+" : "")\(Int(settings.notchAdjustedWidth)) pt")
                    Slider(value: $settings.notchAdjustedWidth, in: -60...60, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Height \(settings.notchAdjustedHeight >= 0 ? "+" : "")\(Int(settings.notchAdjustedHeight)) pt")
                    Slider(value: $settings.notchAdjustedHeight, in: -12...16, step: 1)
                }
                Button("Reset calibration") {
                    settings.notchAdjustedWidth = 0
                    settings.notchAdjustedHeight = 0
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Privacy

    private var privacy: some View {
        Form {
            // macOS never re-prompts once someone has said no, so a denied permission is invisible
            // and permanent unless the app says so and points at the pane that fixes it.
            Section("Permissions") {
                ForEach(Permission.allCases) { permission in
                    LabeledContent(permission.title) {
                        HStack(spacing: 8) {
                            Text(permissionLabel(permission.status))
                                .foregroundStyle(permissionColor(permission.status))
                            Button("Open") { permission.openSettingsPane() }
                                .buttonStyle(.link)
                        }
                    }
                }
                Text("Tyland never asks for Accessibility or Input Monitoring. Its gestures are "
                     + "delivered by its own window, so they need no permission at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What Tyland can see") {
                capability("Audio", "The waveform taps system audio, and only while the waveform is "
                           + "on screen. Sound is reduced to four loudness numbers on the audio "
                           + "thread — never recorded, stored or sent anywhere.")
                capability("Calendar", "Event titles, times and locations, to show what is next and "
                           + "how long it takes to get there.")
                capability("Location", "Only when an upcoming event has an address, to estimate "
                           + "travel time. Nothing leaves this Mac.")
                capability("Downloads", "File sizes in the folders you choose. Never file contents.")
            }

            Section("Watched folders") {
                LabeledContent("Downloads") {
                    Text("Always watched").foregroundStyle(.secondary)
                }
                ForEach(settings.downloadFolders, id: \.self) { path in
                    HStack {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                        Spacer()
                        Button("Remove") {
                            settings.downloadFolders.removeAll { $0 == path }
                        }
                        .buttonStyle(.link)
                    }
                    .help(path)
                }
                Button("Add folder…") { addDownloadFolder() }
            }

            Section("Downloads") {
                Toggle("Read download sizes from browsers", isOn: $settings.readBrowserDownloadTotals)
                Text("Chrome, Edge, Brave, Vivaldi and Opera record a download's total size in their "
                     + "history database. Reading it is the only way to show an exact progress bar "
                     + "for those browsers. Tyland reads three columns — file path, total bytes and "
                     + "start time — and never URLs or browsing history. Turn this off and downloads "
                     + "show an indeterminate ring instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                let broken = Diagnostics.brokenSymbols
                LabeledContent("System hooks") {
                    Text(broken.isEmpty ? "All working" : "\(broken.count) unavailable")
                        .foregroundStyle(broken.isEmpty ? .green : .orange)
                }
                if !broken.isEmpty {
                    Text("macOS has moved or removed: \(broken.joined(separator: ", ")). "
                         + "The features that used them are switched off rather than misbehaving. "
                         + "An update usually restores them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Contact support…") { Diagnostics.composeSupportEmail() }
                Text("Opens an email with your version, macOS build and which system hooks are "
                     + "working. Nothing is sent automatically, and nothing is collected in the "
                     + "background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Lock screen widgets") {
                Toggle("Show widgets on the lock screen", isOn: $settings.lockScreenEnabled)
                Text("Experimental. This uses undocumented window APIs and may break in any macOS "
                     + "update. If the lock screen ever misbehaves, recover from Terminal:\n"
                     + App.defaultsCommand("lockScreenEnabled", "-bool NO") + " && pkill -x Tyland")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if settings.lockScreenEnabled {
                    LabeledContent("Position") {
                        HStack {
                            Slider(value: $settings.lockScreenPosition, in: 0.5...0.9, step: 0.01)
                            Text(String(format: "%.2f", settings.lockScreenPosition))
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The app is not sandboxed, so a plain path is enough — no security-scoped bookmark needed.
    /// macOS still gates the folder through TCC on first read, which is the honest behaviour.
    private func addDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose a folder to watch for downloads."
        guard panel.runModal() == .OK else { return }
        var folders = settings.downloadFolders
        for url in panel.urls where !folders.contains(url.path) {
            folders.append(url.path)
        }
        settings.downloadFolders = folders
    }

    // MARK: - Pieces

    private func permissionLabel(_ status: Permission.Status) -> String {
        switch status {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked"
        case .unknown: return "Asked on first use"
        }
    }

    private func permissionColor(_ status: Permission.Status) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .orange
        default: return .secondary
        }
    }

    private func capability(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        suffix: String
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            LabeledContent(title) {
                Text("\(value.wrappedValue)\(suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
