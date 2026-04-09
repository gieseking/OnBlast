import CoreAudio
import Foundation

final class OutputVolumeMonitor: @unchecked Sendable {
    var onButtonEvent: ((ButtonEvent) -> Bool)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.gieseking.OnBlast.OutputVolumeMonitor")
    private let pollInterval: TimeInterval = 0.15
    private let minimumStep: Float32 = 0.03
    private let suppressionInterval: TimeInterval = 0.6

    private var configuration = AppConfiguration()
    private var timer: DispatchSourceTimer?
    private var lastDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var lastDeviceUID = ""
    private var lastDeviceName = ""
    private var lastObservedVolume: Float32?
    private var suppressUntil = Date.distantPast

    func start(configuration: AppConfiguration) {
        stop()

        guard shouldEnable(for: configuration) else {
            return
        }

        self.configuration = configuration

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
        log("Output volume fallback monitor started")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastDeviceID = AudioDeviceID(kAudioObjectUnknown)
        lastDeviceUID = ""
        lastDeviceName = ""
        lastObservedVolume = nil
        suppressUntil = Date.distantPast
    }

    private func shouldEnable(for configuration: AppConfiguration) -> Bool {
        guard configuration.enableOutputVolumeFallback else {
            return false
        }

        return configuration.action(for: .volumeUp) != .passthrough ||
            configuration.action(for: .volumeDown) != .passthrough ||
            configuration.action(for: .mute) != .passthrough
    }

    private func poll() {
        guard !EventInjectionGuard.shared.shouldIgnoreSyntheticEvents else {
            return
        }

        let now = Date()
        guard now >= suppressUntil else {
            return
        }

        guard let snapshot = currentOutputSnapshot() else {
            lastDeviceID = AudioDeviceID(kAudioObjectUnknown)
            lastDeviceUID = ""
            lastDeviceName = ""
            lastObservedVolume = nil
            return
        }

        let filter = configuration.boseNameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesFilter = filter.isEmpty ||
            snapshot.name.localizedCaseInsensitiveContains(filter) ||
            snapshot.manufacturer.localizedCaseInsensitiveContains(filter)

        guard matchesFilter else {
            lastDeviceID = snapshot.deviceID
            lastDeviceUID = snapshot.uid
            lastDeviceName = snapshot.name
            lastObservedVolume = snapshot.volume
            return
        }

        if snapshot.deviceID != lastDeviceID || snapshot.uid != lastDeviceUID {
            lastDeviceID = snapshot.deviceID
            lastDeviceUID = snapshot.uid
            lastDeviceName = snapshot.name
            lastObservedVolume = snapshot.volume
            log("Output volume fallback monitor attached to '\(snapshot.name)'")
            return
        }

        guard let previousVolume = lastObservedVolume else {
            lastObservedVolume = snapshot.volume
            return
        }

        let delta = snapshot.volume - previousVolume
        guard abs(delta) >= minimumStep else {
            lastObservedVolume = snapshot.volume
            return
        }

        let button: ButtonIdentifier = delta > 0 ? .volumeUp : .volumeDown
        let event = ButtonEvent(
            button: button,
            isDown: true,
            isRepeat: false,
            source: .outputVolumeFallback,
            deviceName: snapshot.name,
            rawDescription: "previousVolume=\(previousVolume) currentVolume=\(snapshot.volume) delta=\(delta)"
        )

        let handled = DispatchQueue.main.sync {
            self.onButtonEvent?(event) ?? false
        }

        if handled {
            suppressUntil = now.addingTimeInterval(suppressionInterval)
            if setVolume(previousVolume, for: snapshot.deviceID) {
                lastObservedVolume = previousVolume
                log("Restored output volume on '\(snapshot.name)' after handling \(button.displayName)")
            } else {
                lastObservedVolume = snapshot.volume
                log("Handled \(button.displayName) from output volume fallback, but failed to restore the prior output volume")
            }
        } else {
            lastObservedVolume = snapshot.volume
        }
    }

    private func currentOutputSnapshot() -> OutputSnapshot? {
        guard let deviceID = defaultOutputDeviceID() else {
            return nil
        }

        guard
            let uid = readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID),
            let name = readString(deviceID: deviceID, selector: kAudioObjectPropertyName),
            let manufacturer = readString(deviceID: deviceID, selector: kAudioObjectPropertyManufacturer),
            let volume = readVolume(deviceID: deviceID)
        else {
            return nil
        }

        return OutputSnapshot(
            deviceID: deviceID,
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            volume: volume
        )
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    private func readVolume(deviceID: AudioDeviceID) -> Float32? {
        if let value = readVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return value
        }

        if let left = readVolume(deviceID: deviceID, element: 1),
           let right = readVolume(deviceID: deviceID, element: 2) {
            return (left + right) / 2
        }

        return readVolume(deviceID: deviceID, element: 1) ?? readVolume(deviceID: deviceID, element: 2)
    }

    private func readVolume(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value: Float32 = 0
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &value)
        return status == noErr ? value : nil
    }

    private func setVolume(_ value: Float32, for deviceID: AudioDeviceID) -> Bool {
        let clampedValue = min(max(value, 0), 1)

        if setVolume(clampedValue, for: deviceID, element: kAudioObjectPropertyElementMain) {
            return true
        }

        let left = setVolume(clampedValue, for: deviceID, element: 1)
        let right = setVolume(clampedValue, for: deviceID, element: 2)
        return left || right
    }

    private func setVolume(_ value: Float32, for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue else {
            return false
        }

        var mutableValue = value
        let propertySize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, propertySize, &mutableValue)
        return status == noErr
    }

    private func readString(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, pointer)
        }

        guard status == noErr, let value else {
            return nil
        }

        return value.takeRetainedValue() as String
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.onLog?(message)
        }
    }
}

private struct OutputSnapshot {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let manufacturer: String
    let volume: Float32
}
