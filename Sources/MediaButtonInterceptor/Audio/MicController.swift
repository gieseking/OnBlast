import CoreAudio
import Foundation

enum MicControllerError: LocalizedError {
    case noInputDevice
    case propertyReadFailed(OSStatus)
    case propertyWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No default input device is available."
        case .propertyReadFailed(let status):
            return "Core Audio read failed with status \(status)."
        case .propertyWriteFailed(let status):
            return "Core Audio write failed with status \(status)."
        }
    }
}

final class MicController: MicMuteControlling {
    private var cachedInputVolume: [AudioDeviceID: Float32] = [:]
    var preferredInputDeviceUID: String = ""

    func currentState() -> MicState {
        do {
            return try isMuted() ? .muted : .live
        } catch {
            return .unavailable
        }
    }

    @discardableResult
    func toggleMute() throws -> Bool {
        let muted = try isMuted()
        try setMuted(!muted)
        return !muted
    }

    func isMuted() throws -> Bool {
        let device = try targetInputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        if let value = try? readUInt32(device: device, address: &address) {
            return value != 0
        }

        var fallbackAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volume = try readFloat32(device: device, address: &fallbackAddress)
        return volume <= 0.001
    }

    func setMuted(_ muted: Bool) throws {
        let device = try targetInputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        if try setUInt32IfPossible(device: device, address: &address, value: muted ? 1 : 0) {
            return
        }

        var fallbackAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        if muted {
            cachedInputVolume[device] = (try? readFloat32(device: device, address: &fallbackAddress)) ?? 1.0
            try writeFloat32(device: device, address: &fallbackAddress, value: 0)
        } else {
            let restored = cachedInputVolume[device] ?? 1.0
            try writeFloat32(device: device, address: &fallbackAddress, value: restored)
        }
    }

    private func targetInputDevice() throws -> AudioDeviceID {
        let trimmedPreferredUID = preferredInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreferredUID.isEmpty, let preferredDeviceID = try? deviceID(forUID: trimmedPreferredUID) {
            return preferredDeviceID
        }

        return try defaultInputDevice()
    }

    private func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr else {
            throw MicControllerError.propertyReadFailed(status)
        }

        guard deviceID != kAudioObjectUnknown else {
            throw MicControllerError.noInputDevice
        }

        return deviceID
    }

    private func deviceID(forUID uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var byteCount: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        )

        guard sizeStatus == noErr else {
            throw MicControllerError.propertyReadFailed(sizeStatus)
        }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        let readStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceIDs
        )

        guard readStatus == noErr else {
            throw MicControllerError.propertyReadFailed(readStatus)
        }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var value: Unmanaged<CFString>?
            var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &propertySize, pointer)
            }

            guard status == noErr, let value else {
                continue
            }

            let resolvedUID = value.takeRetainedValue() as String
            if resolvedUID == uid {
                return deviceID
            }
        }

        throw MicControllerError.noInputDevice
    }

    private func readUInt32(device: AudioDeviceID, address: inout AudioObjectPropertyAddress) throws -> UInt32 {
        var value: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &propertySize, &value)

        guard status == noErr else {
            throw MicControllerError.propertyReadFailed(status)
        }

        return value
    }

    private func readFloat32(device: AudioDeviceID, address: inout AudioObjectPropertyAddress) throws -> Float32 {
        var value: Float32 = 0
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &propertySize, &value)

        guard status == noErr else {
            throw MicControllerError.propertyReadFailed(status)
        }

        return value
    }

    private func setUInt32IfPossible(
        device: AudioDeviceID,
        address: inout AudioObjectPropertyAddress,
        value: UInt32
    ) throws -> Bool {
        var isSettable: DarwinBoolean = false
        let checkStatus = AudioObjectIsPropertySettable(device, &address, &isSettable)

        guard checkStatus == noErr, isSettable.boolValue else {
            return false
        }

        var mutableValue = value
        let propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, propertySize, &mutableValue)

        guard status == noErr else {
            throw MicControllerError.propertyWriteFailed(status)
        }

        return true
    }

    private func writeFloat32(
        device: AudioDeviceID,
        address: inout AudioObjectPropertyAddress,
        value: Float32
    ) throws {
        var mutableValue = value
        let propertySize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, propertySize, &mutableValue)

        guard status == noErr else {
            throw MicControllerError.propertyWriteFailed(status)
        }
    }
}
