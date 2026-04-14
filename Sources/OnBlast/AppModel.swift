import ApplicationServices
import AppKit
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
    @Published private(set) var micInputLevel: Double = 0
    @Published private(set) var micInputLevelStatus = "No input device"
    @Published private(set) var discoveredDevices: [HIDDeviceSummary] = []
    @Published private(set) var inputAudioDevices: [AudioDeviceOption] = []
    @Published private(set) var bundledVirtualMicDriverAvailable = false
    @Published private(set) var installedVirtualMicDriverPresent = false
    @Published private(set) var virtualMicDeviceDetected = false
    @Published private(set) var virtualMicDriverInstallInProgress = false
    @Published private(set) var virtualMicSelfTestInProgress = false
    @Published private(set) var virtualMicSelfTestStatus = "Idle"
    @Published private(set) var updateCheckInProgress = false
    @Published private(set) var updateInstallInProgress = false
    @Published private(set) var updateStatus = "Not checked"
    @Published private(set) var availableReleaseVersion = ""
    @Published private(set) var availableReleaseTitle = ""
    @Published private(set) var lastUpdateCheckDescription = "Never"
    @Published private(set) var logLines: [LogEntry] = []

    private let audioDeviceCatalog = AudioDeviceCatalog()
    private let deviceMicController = MicController()
    private let virtualMicProxyController = VirtualMicProxyController()
    private let virtualMicDriverInstaller = VirtualMicDriverInstaller()
    private let virtualMicSelfTestController = VirtualMicSelfTestController()
    private let releaseUpdater = ReleaseUpdater()
    private let micSpeechActivityMonitor = MicSpeechActivityMonitor()
    private let micInputLevelMonitor = MicInputLevelMonitor()
    private let micStateRecoveryMonitor = MicStateRecoveryMonitor()
    private let outputVolumeMonitor = OutputVolumeMonitor()
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
    private var hasRestoredPersistedMicState = false
    private var autoUpdateTimer: Timer?
    private var cachedAvailableRelease: ReleaseInfo?

    init() {
        config = AppConfiguration.load()

        dispatcher.onLog = { [weak self] in self?.appendLog($0) }
        virtualMicProxyController.onLog = { [weak self] in self?.appendLog($0) }
        virtualMicProxyController.onSpeechDetected = { [weak self] in
            self?.handleSpeechDetectedWhileMuted($0)
        }
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
        releaseUpdater.onLog = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
        micSpeechActivityMonitor.onLog = { [weak self] in self?.appendLog($0) }
        micSpeechActivityMonitor.onSpeechDetected = { [weak self] in
            self?.handleSpeechDetectedWhileMuted($0)
        }
        micInputLevelMonitor.onLog = { [weak self] in self?.appendLog($0) }
        micInputLevelMonitor.onLevelChange = { [weak self] level in
            Task { @MainActor in
                self?.micInputLevel = level
            }
        }
        micInputLevelMonitor.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.micInputLevelStatus = status
            }
        }
        micStateRecoveryMonitor.onLog = { [weak self] in self?.appendLog($0) }
        micStateRecoveryMonitor.onStateChange = { [weak self] deviceTopologyMayHaveChanged in
            self?.handleObservedMicStateChange(deviceTopologyMayHaveChanged: deviceTopologyMayHaveChanged)
        }
        outputVolumeMonitor.onLog = { [weak self] in self?.appendLog($0) }
        outputVolumeMonitor.onButtonEvent = { [weak self] in self?.handleInterceptableButtonEvent($0) ?? false }
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
        settingsWindowCoordinator.setVisibilityChangeHandler { [weak self] isVisible in
            self?.updateActivationPolicyForSettingsVisibility(isVisible)
        }

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
        guard canToggleMicMute else {
            if let reason = mutedActionUnavailableReason {
                appendLog("Ignoring mute toggle because \(reason)")
            } else {
                appendLog("Ignoring mute toggle because the virtual mic backend is not ready")
            }
            return
        }

        dispatcher.perform(.toggleMicMute, micController: activeMicController, privateBridge: privateBridge)
        micState = activeMicController.currentState()
    }

    func openSettingsWindow() {
        settingsWindowCoordinator.show(model: self)
    }

    private func updateActivationPolicyForSettingsVisibility(_ isVisible: Bool) {
        NSApp.setActivationPolicy(isVisible ? .regular : .accessory)
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

    func checkForUpdatesManually() {
        guard !updateCheckInProgress, !updateInstallInProgress else {
            return
        }

        Task {
            await performUpdateCheck(installIfAvailable: false, sourceDescription: "manual")
        }
    }

    func installAvailableUpdate() {
        guard !updateInstallInProgress else {
            return
        }

        guard let release = cachedAvailableRelease else {
            updateStatus = "No pending update is available"
            return
        }

        Task {
            await installRelease(release, sourceDescription: "manual")
        }
    }

    func openReleasesPage() {
        guard let url = URL(string: "https://github.com/gieseking/OnBlast/releases") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func refreshRuntimeState() {
        let previousAccessibilityGranted = accessibilityGranted
        let previousMicState = micState
        accessibilityGranted = AXIsProcessTrusted()
        micState = activeMicController.currentState()

        let bundleID = Bundle.main.bundleIdentifier ?? "com.gieseking.OnBlast"
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

        if previousConfiguration == nil || previousConfiguration?.micMuteBackend != config.micMuteBackend {
            hasRestoredPersistedMicState = false
            restorePersistedMicState(reason: previousConfiguration == nil ? "startup" : "backend switch")
        }

        if previousConfiguration == nil ||
            previousConfiguration?.micMuteBackend != config.micMuteBackend ||
            previousConfiguration?.virtualMicInputDeviceUID != config.virtualMicInputDeviceUID {
            if config.micMuteBackend == .virtualMicProxy {
                if !requestedVirtualMicInputDeviceUID.isEmpty, requestedVirtualMicInputDeviceMissing {
                    appendLog("Virtual mic proxy selected, but the chosen source mic is not currently connected")
                } else if virtualMicDeviceDetected {
                    appendLog("Virtual mic proxy selected with source mic '\(requestedVirtualMicInputDeviceName)'")
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
            previousConfiguration?.enableMutedSpeechReminder != config.enableMutedSpeechReminder ||
            previousConfiguration?.micMuteBackend != config.micMuteBackend {
            micSpeechActivityMonitor.start(enabled: shouldUseStandaloneMutedSpeechMonitor)
        }

        if previousConfiguration == nil ||
            previousConfiguration?.enableOutputVolumeFallback != config.enableOutputVolumeFallback ||
            previousConfiguration?.boseNameFilter != config.boseNameFilter ||
            previousConfiguration?.consumeInterceptedEvents != config.consumeInterceptedEvents ||
            previousConfiguration?.action(for: .volumeUp) != config.action(for: .volumeUp) ||
            previousConfiguration?.action(for: .volumeDown) != config.action(for: .volumeDown) ||
            previousConfiguration?.action(for: .mute) != config.action(for: .mute) {
            outputVolumeMonitor.start(configuration: config)
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

        let bundleID = Bundle.main.bundleIdentifier ?? "com.gieseking.OnBlast"
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

        if previousConfiguration == nil || previousConfiguration?.enableAutomaticUpdates != config.enableAutomaticUpdates {
            configureAutomaticUpdateChecks(runImmediateCheck: previousConfiguration == nil || config.enableAutomaticUpdates)
        }
    }

    private func applyAudioDeviceDependentConfiguration() {
        deviceMicController.preferredInputDeviceUID = resolvedPhysicalInputDeviceUID
        micStateRecoveryMonitor.configure(
            enabled: config.micMuteBackend == .deviceMute,
            preferredInputDeviceUID: resolvedPhysicalInputDeviceUID,
            followSystemDefaultInput: config.virtualMicInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        micInputLevelMonitor.configure(
            selectedInputDeviceUID: resolvedMicInputLevelDeviceUID,
            selectedInputDeviceName: resolvedMicInputLevelDeviceName
        )
        virtualMicProxyController.configure(
            enabled: config.micMuteBackend == .virtualMicProxy,
            selectedInputDeviceUID: requestedVirtualMicInputDeviceUID,
            selectedInputDeviceName: requestedVirtualMicInputDeviceName,
            selectedInputSampleRate: requestedVirtualMicInputSampleRate,
            speechDetectionEnabled: config.enableMutedSpeechReminder,
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

    private func handleObservedMicStateChange(deviceTopologyMayHaveChanged: Bool) {
        let previousMicState = micState
        refreshRuntimeState()

        if deviceTopologyMayHaveChanged {
            refreshAudioDevicesAsync(forceReconfigure: true)
        }

        if previousMicState != micState {
            appendLog("Recovered microphone state after an external change: \(micState.displayName)")
        }
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

        if action == .toggleMicMute, !canToggleMicMute {
            if let reason = mutedActionUnavailableReason {
                appendLog("Ignoring mute toggle mapping because \(reason)")
            } else {
                appendLog("Ignoring mute toggle mapping because the virtual mic backend is not ready")
            }
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

        hasRestoredPersistedMicState = true

        switch newMicState {
        case .muted:
            persistPreferredMicState(isMuted: true)
            mutedSpeechReminderArmed = true
            micSpeechActivityMonitor.suppressDetection(for: 1.5)
        case .live, .disconnected, .unavailable, .unknown:
            if newMicState == .live {
                persistPreferredMicState(isMuted: false)
            }
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

        guard shouldTriggerMutedSpeechReminder() else {
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

    private func shouldTriggerMutedSpeechReminder() -> Bool {
        guard config.onlyTriggerMutedSpeechReminderWhenMeetingAppActive else {
            return true
        }

        guard let activeMeetingApp = activeMeetingApplicationDescription() else {
            appendLog("Skipped muted reminder because Zoom, Teams, or Meet is not active")
            return false
        }

        appendLog("Muted reminder gated by active meeting app: \(activeMeetingApp)")
        return true
    }

    private func activeMeetingApplicationDescription() -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier else {
            return nil
        }

        switch bundleIdentifier {
        case "us.zoom.xos":
            return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams":
            return "Teams"
        default:
            guard browserBundleIdentifiers.contains(bundleIdentifier) else {
                return nil
            }

            guard let windowTitle = focusedWindowTitle(for: application),
                  windowTitle.localizedCaseInsensitiveContains("meet") else {
                return nil
            }

            return "Google Meet"
        }
    }

    private func focusedWindowTitle(for application: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        let focusedWindowStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedWindowStatus == .success,
              let focusedWindow = focusedWindowValue else {
            return nil
        }

        let windowElement = focusedWindow as! AXUIElement
        var titleValue: CFTypeRef?
        let titleStatus = AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )

        guard titleStatus == .success else {
            return nil
        }

        return titleValue as? String
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

    private let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac"
    ]

    private var activeMicController: MicMuteControlling {
        switch config.micMuteBackend {
        case .deviceMute:
            return deviceMicController
        case .virtualMicProxy:
            return virtualMicProxyController
        }
    }

    var canToggleMicMute: Bool {
        switch config.micMuteBackend {
        case .deviceMute:
            return true
        case .virtualMicProxy:
            return virtualMicDeviceDetected &&
                !resolvedBundledVirtualMicDeviceUID.isEmpty &&
                !resolvedPhysicalInputDeviceUID.isEmpty
        }
    }

    private var mutedActionUnavailableReason: String? {
        guard config.micMuteBackend == .virtualMicProxy else {
            return nil
        }

        if !virtualMicDeviceDetected {
            return "the virtual microphone device is not detected"
        }

        if resolvedBundledVirtualMicDeviceUID.isEmpty {
            return "the virtual microphone backend is not ready yet"
        }

        if resolvedPhysicalInputDeviceUID.isEmpty {
            return "no proxy input microphone is selected"
        }

        return nil
    }

    private var shouldUseStandaloneMutedSpeechMonitor: Bool {
        config.enableMutedSpeechReminder && config.micMuteBackend == .deviceMute
    }

    private func restorePersistedMicState(reason: String) {
        guard !hasRestoredPersistedMicState else {
            return
        }

        let desiredMuted = config.restoreMutedStateOnLaunch

        do {
            let currentState = activeMicController.currentState()
            if currentState == .muted && desiredMuted {
                hasRestoredPersistedMicState = true
                return
            }
            if currentState == .live && !desiredMuted {
                hasRestoredPersistedMicState = true
                return
            }

            try activeMicController.setMuted(desiredMuted)
            let previousState = micState
            let restoredState = activeMicController.currentState()
            micState = restoredState
            hasRestoredPersistedMicState = true
            appendLog("Restored microphone state to \(desiredMuted ? "muted" : "live") on \(reason)")
            handleMicStateTransition(from: previousState, to: restoredState)
        } catch {
            appendLog("Failed to restore microphone state on \(reason): \(error.localizedDescription)")
        }
    }

    private func persistPreferredMicState(isMuted: Bool) {
        guard config.restoreMutedStateOnLaunch != isMuted else {
            return
        }

        config.restoreMutedStateOnLaunch = isMuted
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

    private var requestedVirtualMicInputDeviceUID: String {
        let trimmed = config.virtualMicInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        return resolvedPhysicalInputDeviceUID
    }

    private var requestedVirtualMicInputDeviceMissing: Bool {
        let requestedUID = requestedVirtualMicInputDeviceUID
        guard !requestedUID.isEmpty else {
            return false
        }

        return inputAudioDevices.contains(where: { $0.uid == requestedUID }) == false
    }

    private var resolvedBundledVirtualMicDeviceUID: String {
        let trimmed = config.virtualMicOutputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let matchingDevice = cachedAudioDevices.first(where: { $0.uid == trimmed }),
           matchingDevice.name == AudioDeviceCatalog.bundledVirtualMicDeviceName {
            return trimmed
        }

        return audioDeviceCatalog.bundledVirtualMicDevice(from: cachedAudioDevices)?.uid ?? ""
    }

    private var resolvedBundledVirtualMicDeviceName: String {
        let resolvedUID = resolvedBundledVirtualMicDeviceUID
        return cachedAudioDevices.first(where: { $0.uid == resolvedUID })?.name
            ?? AudioDeviceCatalog.bundledVirtualMicDeviceName
    }

    private var resolvedMicInputLevelDeviceUID: String {
        switch config.micMuteBackend {
        case .deviceMute:
            return resolvedPhysicalInputDeviceUID
        case .virtualMicProxy:
            return resolvedBundledVirtualMicDeviceUID
        }
    }

    private var resolvedMicInputLevelDeviceName: String {
        switch config.micMuteBackend {
        case .deviceMute:
            return resolvedPhysicalInputDeviceName
        case .virtualMicProxy:
            return resolvedBundledVirtualMicDeviceName
        }
    }

    private var resolvedPhysicalInputDeviceName: String {
        let resolvedUID = resolvedPhysicalInputDeviceUID
        return inputAudioDevices.first(where: { $0.uid == resolvedUID })?.name ?? "Automatic"
    }

    private var resolvedPhysicalInputSampleRate: Double {
        let resolvedUID = resolvedPhysicalInputDeviceUID
        return inputAudioDevices.first(where: { $0.uid == resolvedUID })?.nominalSampleRate ?? 48_000
    }

    private var requestedVirtualMicInputDeviceName: String {
        let requestedUID = requestedVirtualMicInputDeviceUID
        guard !requestedUID.isEmpty else {
            return "Automatic"
        }

        return inputAudioDevices.first(where: { $0.uid == requestedUID })?.name ?? "Selected microphone"
    }

    private var requestedVirtualMicInputSampleRate: Double {
        let requestedUID = requestedVirtualMicInputDeviceUID
        guard !requestedUID.isEmpty else {
            return resolvedPhysicalInputSampleRate
        }

        return inputAudioDevices.first(where: { $0.uid == requestedUID })?.nominalSampleRate ?? 48_000
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

    private func configureAutomaticUpdateChecks(runImmediateCheck: Bool) {
        autoUpdateTimer?.invalidate()
        autoUpdateTimer = nil

        guard config.enableAutomaticUpdates else {
            if updateStatus == "Not checked" || updateStatus.hasPrefix("Automatic updates") {
                updateStatus = "Automatic updates are disabled"
            }
            return
        }

        updateStatus = "Automatic updates are enabled"
        autoUpdateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performUpdateCheck(installIfAvailable: true, sourceDescription: "automatic")
            }
        }

        guard runImmediateCheck else {
            return
        }

        Task {
            await performUpdateCheck(installIfAvailable: true, sourceDescription: "automatic")
        }
    }

    private func performUpdateCheck(installIfAvailable: Bool, sourceDescription: String) async {
        guard !updateCheckInProgress, !updateInstallInProgress else {
            return
        }

        updateCheckInProgress = true
        updateStatus = "Checking GitHub Releases..."

        defer {
            updateCheckInProgress = false
        }

        do {
            let latestRelease = try await releaseUpdater.fetchLatestRelease()
            lastUpdateCheckDescription = Self.updateDateFormatter.string(from: Date())

            guard let currentVersion = ReleaseVersion(releaseUpdater.currentVersionString) else {
                cachedAvailableRelease = nil
                availableReleaseVersion = ""
                availableReleaseTitle = ""
                updateStatus = "Current app version is invalid"
                return
            }

            if latestRelease.version > currentVersion {
                cachedAvailableRelease = latestRelease
                availableReleaseVersion = latestRelease.version.description
                availableReleaseTitle = latestRelease.title
                updateStatus = "Update available: \(latestRelease.version.description)"
                appendLog("GitHub Releases reports a newer version \(latestRelease.version.description)")

                if installIfAvailable && config.enableAutomaticUpdates {
                    await installRelease(latestRelease, sourceDescription: sourceDescription)
                }
            } else {
                cachedAvailableRelease = nil
                availableReleaseVersion = ""
                availableReleaseTitle = ""
                updateStatus = "OnBlast is up to date"
            }
        } catch {
            cachedAvailableRelease = nil
            availableReleaseVersion = ""
            availableReleaseTitle = ""
            updateStatus = "Update check failed: \(error.localizedDescription)"
            appendLog("Update check failed: \(error.localizedDescription)")
        }
    }

    private func installRelease(_ release: ReleaseInfo, sourceDescription: String) async {
        guard !updateInstallInProgress else {
            return
        }

        guard let bundleURL = Bundle.main.bundleURLIfAppBundle else {
            updateStatus = "Updates require OnBlast to run from an installed .app bundle"
            return
        }

        updateInstallInProgress = true
        updateStatus = "Installing \(release.version.description)..."
        appendLog("Starting \(sourceDescription) update to \(release.version.description)")

        defer {
            updateInstallInProgress = false
        }

        do {
            try await releaseUpdater.installRelease(
                release,
                over: bundleURL,
                currentProcessID: ProcessInfo.processInfo.processIdentifier
            )

            updateStatus = "Update scheduled. OnBlast will restart."
            appendLog("Update to \(release.version.description) was scheduled successfully")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        } catch {
            updateStatus = "Update install failed: \(error.localizedDescription)"
            appendLog("Update install failed: \(error.localizedDescription)")
        }
    }

    var appVersionDisplay: String {
        "\(releaseUpdater.currentVersionString) (\(releaseUpdater.currentBuildString))"
    }

    var appInstallLocationDescription: String {
        releaseUpdater.currentBundlePath
    }

    var updateAvailable: Bool {
        cachedAvailableRelease != nil
    }

    private func allNonInputAudioDevices() -> [AudioDeviceOption] {
        cachedAudioDevices.filter { $0.inputChannelCount == 0 || $0.isVirtual }
    }

    private static let updateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension Bundle {
    var bundleURLIfAppBundle: URL? {
        let url = bundleURL
        return url.pathExtension == "app" ? url : nil
    }
}
