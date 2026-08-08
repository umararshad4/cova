import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    let geometry: NotchGeometry

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            widgets.tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
            sounds.tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
            notch.tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
        }
        .frame(width: 440, height: 430)
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
                Toggle("Disable entirely in full screen", isOn: $settings.disableWhileInFullscreen)
                Toggle("Hide from screen capture", isOn: $settings.hideFromScreenCapture)
                Toggle("Hide menu bar icon", isOn: $settings.hideMenuBarIcon)
                if settings.hideMenuBarIcon {
                    Text("With the icon hidden, re-open Settings from Terminal:\n"
                         + "defaults write dev.local.tyland hideMenuBarIcon -bool NO")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Show on", selection: $settings.showOnDisplay) {
                    Text("Built-in display").tag("builtInDisplay")
                    Text("Active display").tag("activeDisplay")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Widgets

    private var widgets: some View {
        Form {
            Section("Music") {
                Picker("Source", selection: $settings.musicApp) {
                    Text("System (any player)").tag("system")
                    Text("Apple Music").tag("music")
                    Text("Spotify").tag("spotify")
                }
                Toggle("Live waveform", isOn: $settings.showWaveform)
            }

            Section("Devices") {
                Toggle("Warn on low device battery", isOn: $settings.warnOnLowConnectBattery)
            }

            Section("Gestures") {
                Toggle("Natural swipe direction", isOn: $settings.naturalMovement)
                Toggle("Tint gestures with accent colour", isOn: $settings.useAccentColorOnGestures)
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
                Text("Changes apply on relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
