import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "slider.horizontal.3")
                }

            mappingsTab
                .tabItem {
                    Label("Mappings", systemImage: "keyboard")
                }

            devicesTab
                .tabItem {
                    Label("Devices", systemImage: "headphones")
                }

            logsTab
                .tabItem {
                    Label("Logs", systemImage: "text.alignleft")
                }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 760)
    }

    private var generalTab: some View {
        Form {
            Section("Status") {
                LabeledContent("Mic") {
                    Text(model.micState.displayName)
                }
                LabeledContent("Audio Indicator") {
                    MicLevelIndicatorView(
                        level: model.micInputLevel,
                        status: model.micInputLevelStatus
                    )
                }
                LabeledContent("Accessibility") {
                    Text(model.accessibilityGranted ? "Granted" : "Missing")
                }
                LabeledContent("Start at Login") {
                    Text(model.startupStatus)
                }
                LabeledContent("Backend") {
                    Text(model.startupBackendDescription)
                }
            }

            Section("About & Updates") {
                LabeledContent("Version") {
                    Text(model.appVersionDisplay)
                }
                LabeledContent("Installed from") {
                    Text(model.appInstallLocationDescription)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Last checked") {
                    Text(model.lastUpdateCheckDescription)
                }
                LabeledContent("Update status") {
                    Text(model.updateStatus)
                        .multilineTextAlignment(.trailing)
                }

                Toggle("Enable automatic updates", isOn: $model.config.enableAutomaticUpdates)

                if model.updateAvailable {
                    LabeledContent("Latest release") {
                        Text(model.availableReleaseVersion.isEmpty ? model.availableReleaseTitle : model.availableReleaseVersion)
                    }
                }

                HStack {
                    Button("Check for Updates") {
                        model.checkForUpdatesManually()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.updateCheckInProgress || model.updateInstallInProgress)

                    if model.updateAvailable {
                        Button("Install Update") {
                            model.installAvailableUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.updateCheckInProgress || model.updateInstallInProgress)
                    }

                    Button("Open Releases Page") {
                        model.openReleasesPage()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.updateInstallInProgress)

                    if model.updateCheckInProgress || model.updateInstallInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text("Updates are downloaded from GitHub Releases. Installing an update replaces the current app bundle and restarts OnBlast. If the app is installed in /Applications, macOS may prompt for administrator credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.config.startAtLogin)
                Toggle("Enable system-defined event tap", isOn: $model.config.enableSystemDefinedEventTap)
                Toggle("Enable HID monitor", isOn: $model.config.enableHIDMonitor)
                Toggle("Prefer exclusive Bose capture", isOn: $model.config.enableExclusiveBoseCapture)
                Toggle("Consume intercepted events", isOn: $model.config.consumeInterceptedEvents)
                Toggle("Enable experimental MediaRemote bridge", isOn: $model.config.enablePrivateMediaRemoteBridge)
                Toggle("Enable experimental Bluetooth HFP intercept", isOn: $model.config.enableBluetoothHandsFreeMonitor)
                Toggle("Use Siri activation fallback for center button", isOn: $model.config.enableSiriActivationFallback)
                Toggle("Enable experimental output-volume fallback for volume buttons", isOn: $model.config.enableOutputVolumeFallback)
                TextField("Bose device name filter", text: $model.config.boseNameFilter)
                TextField("Menu bar title", text: $model.config.menuBarTitle)
                Text("The Bluetooth HFP intercept tries to catch the headset's voice-recognition command before Siri launches. The Siri fallback stays available as a last resort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The output-volume fallback is downstream and cannot reliably distinguish headset volume buttons from changes made with the mouse or keyboard. Leave it off unless you are explicitly testing that tradeoff.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone Backend") {
                Picker("Mute strategy", selection: $model.config.micMuteBackend) {
                    ForEach(MicMuteBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                Text("Virtual Mic Proxy is for devices where speech detection does not work after mute because a hardware mute path zeros the microphone before the app can inspect it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.config.micMuteBackend == .virtualMicProxy {
                    LabeledContent("Bundled install payload") {
                        Text(model.bundledVirtualMicDriverAvailable ? "Available" : "Missing")
                            .foregroundStyle(model.bundledVirtualMicDriverAvailable ? .green : .secondary)
                    }

                    LabeledContent("System HAL driver") {
                        Text(model.installedVirtualMicDriverPresent ? "Installed" : "Not installed")
                            .foregroundStyle(model.installedVirtualMicDriverPresent ? .green : .secondary)
                    }

                    LabeledContent("Virtual mic device") {
                        Text(model.virtualMicDeviceDetected ? "Detected" : "Not detected")
                            .foregroundStyle(model.virtualMicDeviceDetected ? .green : .secondary)
                    }

                    if model.installedVirtualMicDriverPresent && !model.virtualMicDeviceDetected {
                        Text("The HAL bundle is installed, but Core Audio is not reporting the virtual microphone device yet. Reinstalling from this panel applies the latest bundled driver build and reloads Core Audio.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Button(model.installedVirtualMicDriverPresent ? "Reinstall Virtual Mic Driver" : "Install Virtual Mic Driver") {
                            model.installBundledVirtualMicDriver()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.bundledVirtualMicDriverAvailable || model.virtualMicDriverInstallInProgress)

                        if model.virtualMicDriverInstallInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Picker("Proxy input mic", selection: $model.config.virtualMicInputDeviceUID) {
                        Text("Automatic (Preferred Physical Input)").tag("")
                        ForEach(model.inputAudioDevices) { device in
                            Text("\(device.name) (\(device.manufacturer))").tag(device.uid)
                        }
                    }

                    HStack {
                        Button("Test Virtual Mic") {
                            model.runVirtualMicSelfTest()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.virtualMicDeviceDetected || model.virtualMicSelfTestInProgress)

                        if model.virtualMicSelfTestInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(model.virtualMicSelfTestStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("The self-test records a short sample from the virtual microphone device itself, then plays it back so you can verify the full proxy path is working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("This mode is intended to proxy a chosen physical microphone into a bundled virtual microphone device for apps to use. It is the right backend when hardware mute restrictions prevent post-mute speech detection on a headset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Install copies the bundled virtual audio driver into /Library/Audio/Plug-Ins/HAL and reloads Core Audio. macOS will prompt for an administrator password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("The bundled driver registers the virtual microphone device, and the app now proxies the selected physical microphone into it when live while outputting silence when muted. Reinstall the driver after updates so Core Audio picks up the latest bundled build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Announcements") {
                Toggle("Enable spoken mic-state announcements", isOn: $model.config.enableSpokenAnnouncements)
                Toggle("Replay muted reminder when speech is detected", isOn: $model.config.enableMutedSpeechReminder)
                Toggle("Only trigger muted reminder when Zoom, Teams, or Meet is active", isOn: $model.config.onlyTriggerMutedSpeechReminderWhenMeetingAppActive)
                    .disabled(!model.config.enableMutedSpeechReminder)

                Text("The muted reminder works best on devices that still expose voice activity while muted. Some Bluetooth and hardware mute paths hard-zero the input, which prevents any user-space app from detecting speech after mute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Zoom and Teams are detected directly. Google Meet detection is best effort and uses the active browser window title when Accessibility permission is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Announcement Volume")
                        Spacer()
                        Text("\(Int(model.config.spokenAnnouncementVolume * 100))%")
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $model.config.spokenAnnouncementVolume, in: 0...1)
                        .disabled(!model.config.enableSpokenAnnouncements)
                }

                TextField("Muted phrase", text: $model.config.spokenMutedAnnouncement)
                    .disabled(!model.config.enableSpokenAnnouncements)

                TextField("Live phrase", text: $model.config.spokenLiveAnnouncement)
                    .disabled(!model.config.enableSpokenAnnouncements)

                soundFileRow(
                    title: "Mute sound",
                    path: model.config.muteSoundFilePath,
                    chooseAction: {
                        if let path = chooseAudioFile(initialPath: model.config.muteSoundFilePath) {
                            model.config.muteSoundFilePath = path
                        }
                    },
                    clearAction: {
                        model.config.muteSoundFilePath = ""
                    }
                )

                soundFileRow(
                    title: "Unmute sound",
                    path: model.config.liveSoundFilePath,
                    chooseAction: {
                        if let path = chooseAudioFile(initialPath: model.config.liveSoundFilePath) {
                            model.config.liveSoundFilePath = path
                        }
                    },
                    clearAction: {
                        model.config.liveSoundFilePath = ""
                    }
                )
            }

            Section("Permissions") {
                Button("Prompt for Accessibility Permission") {
                    model.requestAccessibilityPromptIfNeeded()
                }
                .buttonStyle(.bordered)

                Text("Accessibility is only needed for the system-defined event tap path used by some keyboards, remotes, and headset button routes. Your current Bose Bluetooth voice-command path can work without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Input Monitoring, Bluetooth, and Microphone access may still need to be granted manually in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var mappingsTab: some View {
        Form {
            Section("Mappings") {
                ForEach(ButtonIdentifier.allCases) { button in
                    Picker(button.displayName, selection: Binding(
                        get: { model.action(for: button) },
                        set: { model.setAction($0, for: button) }
                    )) {
                        ForEach(ButtonAction.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var devicesTab: some View {
        Form {
            Section("Detected Devices") {
                if model.discoveredDevices.isEmpty {
                    Text("No matching HID devices are currently visible.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.discoveredDevices) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.productName)
                                .font(.headline)
                            Text("\(device.manufacturer) • \(device.transport) • vendor \(device.vendorID) product \(device.productID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if device.isExclusive {
                                Text("Exclusive capture active")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Logs")
                    .font(.headline)
                Spacer()
                Text("\(model.logLines.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List(model.logLines) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func soundFileRow(
        title: String,
        path: String,
        chooseAction: @escaping () -> Void,
        clearAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Choose...", action: chooseAction)
                Button("Clear", action: clearAction)
                    .disabled(path.isEmpty)
            }

            Text(path.isEmpty ? "No file selected" : path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseAudioFile(initialPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.title = "Choose Audio File"
        panel.message = "Select a media file to play for this announcement."

        let trimmedPath = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: trimmedPath).deletingLastPathComponent()
        }

        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

private struct MicLevelIndicatorView: View {
    let level: Double
    let status: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<12, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(barColor(for: index))
                        .frame(width: 4, height: barHeight(for: index))
                }
            }

            Text(status)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var visualLevel: Double {
        let clampedLevel = min(max(level, 0), 1)

        // Boost quiet input and stretch the full range so louder audio reaches
        // the top of the meter instead of stalling around the midpoint.
        let boostedLevel = pow(clampedLevel, 0.45) * 2.0
        return min(max(boostedLevel, 0), 1)
    }

    private func barColor(for index: Int) -> Color {
        let activeBars = Int((visualLevel * 12).rounded(.up))
        if index < activeBars {
            return visualLevel > 0.6 ? .green : .accentColor
        }

        return Color.secondary.opacity(0.18)
    }

    private func barHeight(for index: Int) -> CGFloat {
        4 + CGFloat(index) * 0.9
    }
}
