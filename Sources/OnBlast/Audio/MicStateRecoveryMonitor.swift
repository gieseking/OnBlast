import CoreAudio
import Foundation

final class MicStateRecoveryMonitor: @unchecked Sendable {
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    private let audioDeviceCatalog = AudioDeviceCatalog()
    private let listenerQueue = DispatchQueue(label: "com.gieseking.OnBlast.MicStateRecoveryMonitor")

    private var enabled = false
    private var followSystemDefaultInput = true
    private var preferredInputDeviceUID = ""
    private var observedDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var observedDeviceUID = ""

    private var defaultInputListenerInstalled = false
    private var muteListenerInstalled = false
    private var volumeListenerInstalled = false

    private lazy var defaultInputListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleDefaultInputDeviceChanged()
    }

    private lazy var deviceMuteListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleObservedMicStateChanged(reason: "input mute property changed")
    }

    private lazy var deviceVolumeListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleObservedMicStateChanged(reason: "input volume property changed")
    }

    deinit {
        stop()
    }

    func configure(enabled: Bool, preferredInputDeviceUID: String, followSystemDefaultInput: Bool) {
        self.preferredInputDeviceUID = preferredInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.followSystemDefaultInput = followSystemDefaultInput

        guard enabled else {
            stop()
            return
        }

        self.enabled = true
        installDefaultInputListenerIfNeeded()
        rebindObservedDevice()
    }

    func stop() {
        enabled = false
        removeDeviceListeners()
        removeDefaultInputListener()
    }

    private func handleDefaultInputDeviceChanged() {
        guard enabled else {
            return
        }

        log("Mic state recovery monitor observed a default input device change")
        rebindObservedDevice()
        emitStateChange(deviceTopologyMayHaveChanged: true)
    }

    private func handleObservedMicStateChanged(reason: String) {
        guard enabled else {
            return
        }

        log("Mic state recovery monitor observed an external microphone state change (\(reason))")
        emitStateChange(deviceTopologyMayHaveChanged: false)
    }

    private func emitStateChange(deviceTopologyMayHaveChanged: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(deviceTopologyMayHaveChanged)
        }
    }

    private func rebindObservedDevice() {
        let targetDeviceID = resolvedTargetInputDeviceID()
        let targetDeviceUID = resolvedTargetInputDeviceUID(for: targetDeviceID)

        guard targetDeviceID != observedDeviceID || targetDeviceUID != observedDeviceUID else {
            return
        }

        removeDeviceListeners()
        observedDeviceID = targetDeviceID
        observedDeviceUID = targetDeviceUID

        guard observedDeviceID != kAudioObjectUnknown else {
            log("Mic state recovery monitor could not find an input device to observe")
            return
        }

        installDeviceListener(
            selector: kAudioDevicePropertyMute,
            listenerBlock: deviceMuteListenerBlock,
            installedFlag: &muteListenerInstalled
        )
        installDeviceListener(
            selector: kAudioDevicePropertyVolumeScalar,
            listenerBlock: deviceVolumeListenerBlock,
            installedFlag: &volumeListenerInstalled
        )

        let deviceDescription = observedDeviceUID.isEmpty ? "device \(observedDeviceID)" : observedDeviceUID
        log("Mic state recovery monitor is observing \(deviceDescription)")
    }

    private func installDefaultInputListenerIfNeeded() {
        guard !defaultInputListenerInstalled else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            defaultInputListenerBlock
        )

        guard status == noErr else {
            log("Failed to install default-input recovery listener: \(status)")
            return
        }

        defaultInputListenerInstalled = true
    }

    private func removeDefaultInputListener() {
        guard defaultInputListenerInstalled else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            defaultInputListenerBlock
        )
        defaultInputListenerInstalled = false
    }

    private func installDeviceListener(
        selector: AudioObjectPropertySelector,
        listenerBlock: @escaping AudioObjectPropertyListenerBlock,
        installedFlag: inout Bool
    ) {
        guard !installedFlag else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(observedDeviceID, &address) else {
            return
        }

        let status = AudioObjectAddPropertyListenerBlock(
            observedDeviceID,
            &address,
            listenerQueue,
            listenerBlock
        )

        guard status == noErr else {
            log("Failed to install mic recovery listener for selector \(selector): \(status)")
            return
        }

        installedFlag = true
    }

    private func removeDeviceListeners() {
        guard observedDeviceID != kAudioObjectUnknown else {
            observedDeviceUID = ""
            return
        }

        removeDeviceListener(
            selector: kAudioDevicePropertyMute,
            listenerBlock: deviceMuteListenerBlock,
            installedFlag: &muteListenerInstalled
        )
        removeDeviceListener(
            selector: kAudioDevicePropertyVolumeScalar,
            listenerBlock: deviceVolumeListenerBlock,
            installedFlag: &volumeListenerInstalled
        )

        observedDeviceID = AudioDeviceID(kAudioObjectUnknown)
        observedDeviceUID = ""
    }

    private func removeDeviceListener(
        selector: AudioObjectPropertySelector,
        listenerBlock: @escaping AudioObjectPropertyListenerBlock,
        installedFlag: inout Bool
    ) {
        guard installedFlag else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            observedDeviceID,
            &address,
            listenerQueue,
            listenerBlock
        )
        installedFlag = false
    }

    private func resolvedTargetInputDeviceID() -> AudioDeviceID {
        if !followSystemDefaultInput,
           let preferredDeviceID = audioDeviceCatalog.deviceID(forUID: preferredInputDeviceUID) {
            return preferredDeviceID
        }

        guard let defaultUID = audioDeviceCatalog.defaultInputDeviceUID(),
              let defaultDeviceID = audioDeviceCatalog.deviceID(forUID: defaultUID) else {
            return AudioDeviceID(kAudioObjectUnknown)
        }

        return defaultDeviceID
    }

    private func resolvedTargetInputDeviceUID(for deviceID: AudioDeviceID) -> String {
        guard deviceID != kAudioObjectUnknown else {
            return ""
        }

        return audioDeviceCatalog.deviceUID(for: deviceID) ?? ""
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(message)
        }
    }
}
