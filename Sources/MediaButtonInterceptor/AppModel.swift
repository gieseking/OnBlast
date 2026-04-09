import ApplicationServices
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfiguration {
        didSet {
            guard isReady else { return }
            config.save()
            applyConfiguration(previousConfiguration: oldValue)
        }
    }

    @Published private(set) var micState: MicState = .unknown
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var startupStatus = "Unknown"
    @Published private(set) var startupBackendDescription = StartupManager.Backend.disabled.rawValue
    @Published private(set) var discoveredDevices: [HIDDeviceSummary] = []
    @Published private(set) var inputAudioDevices: [AudioDeviceOption] = []
    @Published private(set) var bundledVirtualMicDriverAvailable = false
    @Published private(set) var installedVirtualMicDriverPresent = false
    @Published private(set) var virtualMicDeviceDetected = false
    @Published private(set) var virtualMicDriverInstallInProgress = false
    @Published private(set) var virtualMicSelfTestInProgress = false
    @Published private(set) var virtualMicSelfTestStatus = "Idle"
    @Published private(set) var logLines: [LogEntry] = []

    private let audioDeviceCatalog = AudioDeviceCatalog()
    private let deviceMicController = MicController()
    private let virtualMicProxyController = VirtualMicProxyController()
    private let virtualMicDriverInstaller = VirtualMicDriverInstaller()
    private let virtualMicSelfTestController = VirtualMicSelfTestController()
    private let micSpeechActivityMonitor = MicSpeechActivityMonitor()
    private let dispatcher = ActionDispatcher()
    private let systemDefinedEventTap = SystemDefinedEventTap()
    private let hidMonitor = HIDEventMonitor()
    private let privateBridge = PrivateMediaRemoteBridge()
    private let bluetoothHandsFreeMonitor = BluetoothHandsFreeMonitor()
    private let privateBluetoothManagerMonitor = PrivateBluetoothManagerMonitor()
    private let unifiedSystemLogMonitor = UnifiedSystemLogMonitor()
    private let siriActivationMonitor = SiriActivationMonitor()
    private let startupManager = StartupManager()
    private let settingsWindowCoordinator = SettingsWindowCoordinator()
    private var refreshTimer: Timer?
    private var isReady = false
    private var suppressSiriFallbackUntil = Date.distantPast
    private var lastAppliedSystemTapEnabled: Bool?
    private var mutedSpeechReminderArmed = false
    private var cachedAudioDevices: [AudioDeviceOption] = []
    private var cachedDefaultInputDeviceUID: String?
    private var audioDeviceRefreshInFlight = false
    private var audioDeviceRefreshNeedsReconfigure = false

    init() {
        config = AppConfiguration.load()

        dispatcher.onLog = { [weak self] in self?.appendLog($0) }
        virtualMicProxyController.onLog = { [weak self] in self?.appendLog($0) }
        virtualMicDriverInstaller.onLog = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
        virtualMicSelfTestController.onLog = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
        virtualMicSelfTestController.onStatusChange = { [weak self] status, isBusy in
            Task { @MainActor in
                self?.virtualMicSelfTestStatus = status
                self?.virtualMicSelfTestInProgress = isBusy
            }
        }
        micSpeechActivityMonitor.onLog = { [weak self] in self?.appendLog($0) }
        micSpeechActivityMonitor.onSpeechDetected = { [weak self] in
            self?.handleSpeechDetectedWhileMuted($0)
        }
        systemDefinedEventTap.onLog = { [weak self] in self?.appendLog($0) }
        systemDefinedEventTap.onButtonEvent = { [weak self] in self?.handleInterceptableButtonEvent($0) ?? false }
        hidMonitor.onLog = { [weak self] in self?.appendLog($0) }
        hidMonitor.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                self?.discoveredDevices = devices
            }
        }
        hidMonitor.onButtonEvent = { [weak self] in self?.handleInterceptableButtonEvent($0) ?? false }
        privateBridge.onLog = { [weak self] in self?.appendLog($0) }
        privateBridge.onButtonEvent = { [weak self] in self?.handleInterceptableButtonEvent($0) ?? false }
        bluetoothHandsFreeMonitor.onLog = { [weak self] in self?.appendLog($0) }
        bluetoothHandsFreeMonitor.onButtonEvent = { [weak self] in self?.handleInterceptableButtonEvent($0) ?? false }
        privateBluetoothManagerMonitor.onLog = { [weak self] in self?.appendLog($0) }
        unifiedSystemLogMonitor.onLog = { [weak self] in self?.appendLog($0) }
        unifiedSystemLogMonitor.onButtonEvent = { [weak self] in self?.handleInterceptableButtonEvent($0) ?? false }
        siriActivationMonitor.onLog = { [weak self] in self?.appendLog($0) }
        siriActivationMonitor.onButtonEvent = { [weak self] in self?.handleFallbackButtonEvent($0) ?? false }

        isReady = true
        refreshRuntimeState()
        applyConfiguration(previousConfiguration: nil)
        refreshAudioDevicesAsync(forceReconfigure: true)
        startPolling()
    }

    func action(for button: ButtonIdentifier) -> ButtonAction {
        config.action(for: button)
    }

    func setAction(_ action: ButtonAction, for button: ButtonIdentifier) {
        config.setAction(action, for: button)
    }

    func toggleMicMute() {
        dispatcher.perform(.toggleMicMute, micController: activeMicController, privateBridge: privateBridge)
        micState = activeMicController.currentState()
    }

    func openSettingsWindow() {
        settingsWindowCoordinator.show(model: self)
    }

    func requestAccessibilityPromptIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        updateSystemDefinedEventTap(force: true)
    }

    func installBundledVirtualMicDriver() {
        guard !virtualMicDriverInstallInProgress else {
            return
        }

        guard bundledVirtualMicDriverAvailable else {
            appendLog("The app bundle does not contain a bundled virtual mic driver payload")
            return
        }

        let installer = virtualMicDriverInstaller
        virtualMicDriverInstallInProgress = true
        appendLog("Requesting administrator authorization to install the bundled virtual mic driver")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try installer.installBundledDriver()
                Task { @MainActor in
                    self?.virtualMicDriverInstallInProgress = false
                    self?.appendLog("Virtual mic driver installation completed")
                    self?.refreshRuntimeState()
                    self?.refreshAudioDevicesAsync(forceReconfigure: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.refreshRuntimeState()
                        self?.refreshAudioDevicesAsync(forceReconfigure: true)
                    }
                }
            } catch {
                Task { @MainActor in
                    self?.virtualMicDriverInstallInProgress = false
                    self?.appendLog("Failed to install virtual mic driver: \(error.localizedDescription)")
                }
            }
        }
    }

    func runVirtualMicSelfTest() {
        guard virtualMicDeviceDetected else {
            virtualMicSelfTestStatus = "Install or detect the virtual mic device first"
            appendLog("Virtual mic self-test is unavailable because the virtual microphone device is not detected")
            return
        }

        guard micState != .muted else {
            virtualMicSelfTestStatus = "Unmute the microphone before running the self-test"
            appendLog("Virtual mic self-test requires the microphone to be live")
            return
        }

        virtualMicSelfTestController.runTest(
            virtualDeviceUID: resolvedBundledVirtualMicDeviceUID,
            virtualDeviceName: resolvedBundledVirtualMicDeviceName
        )
    }

    func refreshState() {
        refreshRuntimeState()
        refreshAudioDevicesAsync(forceReconfigure: false)
    }

    private func refreshRuntimeState() {
        let previousAccessibilityGranted = accessibilityGranted
        let previousMicState = micState
        accessibilityGranted = AXIsProcessTrusted()
        micState = activeMicController.currentState()

        let bundleID = Bundle.main.bundleIdentifier ?? "com.gieseking.MediaButtonInterceptor"
        startupStatus = startupManager.status(bundleID: bundleID)

        if isReady, previousAccessibilityGranted != accessibilityGranted {
            updateSystemDefinedEventTap(force: true)
        }

        if isReady, previousMicState != micState {
            handleMicStateTransition(from: previousMicState, to: micState)
        }
    }

    private func startPolling() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }
    }

    private func applyConfiguration(previousConfiguration: AppConfiguration?) {
        refreshRuntimeState()
        applyAudioDeviceDependentConfiguration()
        refreshAudioDevicesAsync(forceReconfigure: true)

        if previousConfiguration == nil ||
            previousConfiguration?.micMuteBackend != config.micMuteBackend ||
            previousConfiguration?.virtualMicInputDeviceUID != config.virtualMicInputDeviceUID {
            if config.micMuteBackend == .virtualMicProxy {
                if virtualMicDeviceDetected {
                    appendLog("Virtual mic proxy selected with source mic '\(resolvedPhysicalInputDeviceName)'")
                } else {
                    appendLog("Virtual mic proxy selected, but the virtual microphone device is not detected yet")
                }
            }
        }

        dispatcher.configure(
            spokenAnnouncementsEnabled: config.enableSpokenAnnouncements,
            spokenAnnouncementVolume: config.spokenAnnouncementVolume,
            spokenMutedAnnouncement: config.spokenMutedAnnouncement,
            spokenLiveAnnouncement: config.spokenLiveAnnouncement,
            muteSoundFilePath: config.muteSoundFilePath,
            liveSoundFilePath: config.liveSoundFilePath
        )

        if previousConfiguration == nil ||
            previousConfiguration?.enableMutedSpeechReminder != config.enableMutedSpeechReminder {
            micSpeechActivityMonitor.start(enabled: config.enableMutedSpeechReminder)
        }

        if previousConfiguration == nil ||
            previousConfiguration?.enableSystemDefinedEventTap != config.enableSystemDefinedEventTap {
            updateSystemDefinedEventTap(force: true)
        }

        if previousConfiguration == nil ||
            previousConfiguration?.enableHIDMonitor != config.enableHIDMonitor ||
            previousConfiguration?.enableExclusiveBoseCapture != config.enableExclusiveBoseCapture ||
            previousConfiguration?.boseNameFilter != config.boseNameFilter {
            hidMonitor.start(configuration: config)
        }

        if previousConfiguration == nil ||
            previousConfiguration?.enablePrivateMediaRemoteBridge != config.enablePrivateMediaRemoteBridge {
            privateBridge.start(enabled: config.enablePrivateMediaRemoteBridge, configuration: config)
        }

        if previousConfiguration == nil ||
            previousConfiguration?.enableBluetoothHandsFreeMonitor != config.enableBluetoothHandsFreeMonitor ||
            previousConfiguration?.boseNameFilter != config.boseNameFilter {
            bluetoothHandsFreeMonitor.start(configuration: config)
        }

        if previousConfiguration == nil ||
            previousConfiguration?.enableBluetoothHandsFreeMonitor != config.enableBluetoothHandsFreeMonitor ||
            previousConfiguration?.enableSiriActivationFallback != config.enableSiriActivationFallback {
            privateBluetoothManagerMonitor.start(configuration: config)
        }

        if previousConfiguration == nil ||
            previousConfiguration?.enableBluetoothHandsFreeMonitor != config.enableBluetoothHandsFreeMonitor ||
            previousConfiguration?.enablePrivateMediaRemoteBridge != config.enablePrivateMediaRemoteBridge ||
            previousConfiguration?.enableSiriActivationFallback != config.enableSiriActivationFallback {
            unifiedSystemLogMonitor.start(configuration: config)
        }

        if previousConfiguration == nil ||
            previousConfiguration?.enableSiriActivationFallback != config.enableSiriActivationFallback {
            siriActivationMonitor.start(enabled: config.enableSiriActivationFallback)
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.gieseking.MediaButtonInterceptor"
        if previousConfiguration == nil || previousConfiguration?.startAtLogin != config.startAtLogin {
            if let bundleURL = Bundle.main.bundleURLIfAppBundle {
                do {
                    let backend = try startupManager.apply(enabled: config.startAtLogin, bundleID: bundleID, bundleURL: bundleURL)
                    startupBackendDescription = backend.rawValue
                } catch {
                    startupBackendDescription = "Error"
                    appendLog("Failed to update start-at-login: \(error.localizedDescription)")
                }
            } else {
                startupBackendDescription = "Unavailable outside .app bundle"
            }
        } else if Bundle.main.bundleURLIfAppBundle == nil {
            startupBackendDescription = "Unavailable outside .app bundle"
        }
    }

    private func applyAudioDeviceDependentConfiguration() {
        deviceMicController.preferredInputDeviceUID = resolvedPhysicalInputDeviceUID
        virtualMicProxyController.configure(
            enabled: config.micMuteBackend == .virtualMicProxy,
            selectedInputDeviceUID: resolvedPhysicalInputDeviceUID,
            selectedInputDeviceName: resolvedPhysicalInputDeviceName,
            selectedInputSampleRate: resolvedPhysicalInputSampleRate,
            bundledVirtualDeviceUID: resolvedBundledVirtualMicDeviceUID,
            virtualDeviceDetected: virtualMicDeviceDetected
        )
    }

    private func updateSystemDefinedEventTap(force: Bool = false) {
        let systemTapEnabled = config.enableSystemDefinedEventTap && accessibilityGranted
        guard force || lastAppliedSystemTapEnabled != systemTapEnabled else {
            return
        }

        if config.enableSystemDefinedEventTap && !accessibilityGranted {
            appendLog("System-defined tap is enabled in settings, but Accessibility permission is still missing")
        }

        systemDefinedEventTap.start(enabled: systemTapEnabled)
        lastAppliedSystemTapEnabled = systemTapEnabled
    }

    private func handleInterceptableButtonEvent(_ event: ButtonEvent) -> Bool {
        let wasHandled = handleButtonEvent(event, shouldRespectConsumeSetting: true)

        guard wasHandled, event.button == .voiceCommand else {
            return wasHandled
        }

        suppressSiriFallbackUntil = Date().addingTimeInterval(1.0)
        if event.source == .unifiedSystemVoiceCommand {
            siriActivationMonitor.dismissActiveSiri(reason: "pre-Siri system voice-command log")
        }

        return wasHandled
    }

    private func handleFallbackButtonEvent(_ event: ButtonEvent) -> Bool {
        guard config.enableSiriActivationFallback else {
            appendLog("Ignoring Siri activation because Siri fallback is disabled")
            return false
        }

        if Date() < suppressSiriFallbackUntil {
            appendLog("Ignoring Siri fallback because a pre-Siri voice-command route already handled this press")
            siriActivationMonitor.dismissActiveSiri(reason: "duplicate Siri fallback")
            return true
        }

        return handleButtonEvent(event, shouldRespectConsumeSetting: false)
    }

    private func handleButtonEvent(_ event: ButtonEvent, shouldRespectConsumeSetting: Bool) -> Bool {
        let action = config.action(for: event.button)
        appendLog(
            "Event route=\(event.source.rawValue) button=\(event.button.displayName) state=\(event.isDown ? "down" : "up") repeat=\(event.isRepeat ? "yes" : "no") action=\(action.displayName) device=\(event.deviceName ?? "-") raw={\(event.rawDescription)}"
        )

        guard event.isDown else {
            return action != .passthrough && (shouldRespectConsumeSetting ? config.consumeInterceptedEvents : true)
        }

        guard action != .passthrough else {
            return false
        }

        dispatcher.perform(action, micController: activeMicController, privateBridge: privateBridge)
        let previousMicState = micState
        micState = activeMicController.currentState()
        handleMicStateTransition(from: previousMicState, to: micState)
        return shouldRespectConsumeSetting ? config.consumeInterceptedEvents : true
    }

    private func handleMicStateTransition(from previousMicState: MicState, to newMicState: MicState) {
        guard previousMicState != newMicState else {
            return
        }

        switch newMicState {
        case .muted:
            mutedSpeechReminderArmed = true
            micSpeechActivityMonitor.suppressDetection(for: 1.5)
        case .live, .unavailable, .unknown:
            mutedSpeechReminderArmed = false
        }
    }

    private func handleSpeechDetectedWhileMuted(_ event: MicSpeechDetectionEvent) {
        guard config.enableMutedSpeechReminder else {
            return
        }

        guard micState == .muted else {
            return
        }

        guard mutedSpeechReminderArmed else {
            return
        }

        mutedSpeechReminderArmed = false
        if let level = event.level {
            appendLog(
                "Detected speech while muted via \(event.sourceDescription) (level=\(String(format: "%.3f", level))); replaying muted reminder"
            )
        } else {
            appendLog("Detected speech while muted via \(event.sourceDescription); replaying muted reminder")
        }
        dispatcher.playMutedReminder()
        micSpeechActivityMonitor.suppressDetection(for: 1.5)
    }

    private func appendLog(_ message: String) {
        let timestamp = Self.logDateFormatter.string(from: Date())
        let line = LogEntry(text: "[\(timestamp)] \(message)")
        logLines.append(line)
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var activeMicController: MicMuteControlling {
        switch config.micMuteBackend {
        case .deviceMute:
            return deviceMicController
        case .virtualMicProxy:
            return virtualMicProxyController
        }
    }

    private var resolvedPhysicalInputDeviceUID: String {
        let trimmed = config.virtualMicInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, inputAudioDevices.contains(where: { $0.uid == trimmed }) {
            return trimmed
        }

        if let defaultInputUID = cachedDefaultInputDeviceUID,
           inputAudioDevices.contains(where: { $0.uid == defaultInputUID }) {
            return defaultInputUID
        }

        let trimmedBoseFilter = config.boseNameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBoseFilter.isEmpty,
           let matchingPreferredDevice = inputAudioDevices.first(where: {
               $0.name.localizedCaseInsensitiveContains(trimmedBoseFilter) ||
               $0.manufacturer.localizedCaseInsensitiveContains(trimmedBoseFilter)
           }) {
            return matchingPreferredDevice.uid
        }

        return inputAudioDevices.first?.uid ?? ""
    }

    private var resolvedBundledVirtualMicDeviceUID: String {
        let trimmed = config.virtualMicOutputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return audioDeviceCatalog.bundledVirtualMicDevice(from: cachedAudioDevices)?.uid ?? ""
        }

        return trimmed
    }

    private var resolvedBundledVirtualMicDeviceName: String {
        let resolvedUID = resolvedBundledVirtualMicDeviceUID
        return cachedAudioDevices.first(where: { $0.uid == resolvedUID })?.name
            ?? AudioDeviceCatalog.bundledVirtualMicDeviceName
    }

    private var resolvedPhysicalInputDeviceName: String {
        let resolvedUID = resolvedPhysicalInputDeviceUID
        return inputAudioDevices.first(where: { $0.uid == resolvedUID })?.name ?? "Automatic"
    }

    private var resolvedPhysicalInputSampleRate: Double {
        let resolvedUID = resolvedPhysicalInputDeviceUID
        return inputAudioDevices.first(where: { $0.uid == resolvedUID })?.nominalSampleRate ?? 48_000
    }

    private func refreshAudioDevicesAsync(forceReconfigure: Bool) {
        guard !audioDeviceRefreshInFlight else {
            audioDeviceRefreshNeedsReconfigure = audioDeviceRefreshNeedsReconfigure || forceReconfigure
            return
        }

        audioDeviceRefreshInFlight = true
        audioDeviceRefreshNeedsReconfigure = false
        let audioDeviceCatalog = self.audioDeviceCatalog
        let virtualMicDriverInstaller = self.virtualMicDriverInstaller

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let allDevices = audioDeviceCatalog.allDevices()
            let defaultInputDeviceUID = audioDeviceCatalog.defaultInputDeviceUID()
            let virtualMicDeviceDetected = allDevices.contains { $0.name == AudioDeviceCatalog.bundledVirtualMicDeviceName }
            let bundledDriverAvailable = virtualMicDriverInstaller.isBundledDriverAvailable()
            let installedDriverPresent = virtualMicDriverInstaller.isInstalled()

            Task { @MainActor in
                guard let self else { return }
                self.audioDeviceRefreshInFlight = false
                self.cachedAudioDevices = allDevices
                self.cachedDefaultInputDeviceUID = defaultInputDeviceUID
                self.inputAudioDevices = allDevices.filter { $0.inputChannelCount > 0 && !$0.isVirtual }
                self.virtualMicDeviceDetected = virtualMicDeviceDetected
                self.bundledVirtualMicDriverAvailable = bundledDriverAvailable
                self.installedVirtualMicDriverPresent = installedDriverPresent

                let shouldReconfigure = forceReconfigure || self.audioDeviceRefreshNeedsReconfigure || self.config.micMuteBackend == .virtualMicProxy
                self.audioDeviceRefreshNeedsReconfigure = false

                if shouldReconfigure {
                    self.applyAudioDeviceDependentConfiguration()
                } else {
                    self.deviceMicController.preferredInputDeviceUID = self.resolvedPhysicalInputDeviceUID
                }
            }
        }
    }

    private func allNonInputAudioDevices() -> [AudioDeviceOption] {
        cachedAudioDevices.filter { $0.inputChannelCount == 0 || $0.isVirtual }
    }
}

private extension Bundle {
    var bundleURLIfAppBundle: URL? {
        let url = bundleURL
        return url.pathExtension == "app" ? url : nil
    }
}
