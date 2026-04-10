import CoreAudio
import Foundation

final class AudioDeviceCatalog: @unchecked Sendable {
    static let bundledVirtualMicDeviceName = "OnBlast Virtual Microphone"

    func allDevices() -> [AudioDeviceOption] {
        deviceIDs().compactMap { option(for: $0) }.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func inputDevices() -> [AudioDeviceOption] {
        allDevices().filter { $0.inputChannelCount > 0 }
    }

    func bundledVirtualMicDevice(from devices: [AudioDeviceOption]) -> AudioDeviceOption? {
        devices.first { $0.name == Self.bundledVirtualMicDeviceName }
    }

    func defaultInputDeviceUID() -> String? {
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

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return try? readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUID.isEmpty else {
            return nil
        }

        for deviceID in deviceIDs() {
            guard let deviceUID = try? readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) else {
                continue
            }

            if deviceUID == trimmedUID {
                return deviceID
            }
        }

        return nil
    }

    func deviceUID(for deviceID: AudioDeviceID) -> String? {
        try? readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard var byteCount = try? propertyDataSize(objectID: AudioObjectID(kAudioObjectSystemObject), address: &address) else {
            return []
        }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceIDs
        )

        guard status == noErr else {
            return []
        }

        return deviceIDs
    }

    private func option(for deviceID: AudioDeviceID) -> AudioDeviceOption? {
        let inputChannels = channelCount(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
        let outputChannels = channelCount(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)

        guard inputChannels > 0 || outputChannels > 0 else {
            return nil
        }

        guard
            let uid = try? readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID),
            let name = try? readString(deviceID: deviceID, selector: kAudioObjectPropertyName)
        else {
            return nil
        }

        let manufacturer = (try? readString(deviceID: deviceID, selector: kAudioObjectPropertyManufacturer)) ?? "Unknown"
        let sampleRate = (try? readDouble(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate)) ?? 0
        let transportType = (try? readUInt32(deviceID: deviceID, selector: kAudioDevicePropertyTransportType)) ?? 0
        let transportDescription = transportName(for: transportType)
        let isVirtual = transportType == kAudioDeviceTransportTypeVirtual

        return AudioDeviceOption(
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            transportDescription: transportDescription,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            nominalSampleRate: sampleRate,
            isVirtual: isVirtual
        )
    }

    private func propertyDataSize(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw MicControllerError.propertyReadFailed(status)
        }

        return dataSize
    }

    private func readString(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
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
            throw MicControllerError.propertyReadFailed(status)
        }

        return value.takeRetainedValue() as String
    }

    private func readUInt32(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &value)

        guard status == noErr else {
            throw MicControllerError.propertyReadFailed(status)
        }

        return value
    }

    private func readDouble(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Float64 = 0
        var propertySize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &value)

        guard status == noErr else {
            throw MicControllerError.propertyReadFailed(status)
        }

        return value
    }

    private func channelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard var byteCount = try? propertyDataSize(objectID: deviceID, address: &address), byteCount > 0 else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: Int(byteCount), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawBuffer.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, rawBuffer)
        guard status == noErr else {
            return 0
        }

        let audioBufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let bufferListPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return bufferListPointer.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func transportName(for transportType: UInt32) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-In"
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypeAggregate:
            return "Aggregate"
        case kAudioDeviceTransportTypeAutoAggregate:
            return "Auto Aggregate"
        case kAudioDeviceTransportTypeDisplayPort:
            return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeAirPlay:
            return "AirPlay"
        case kAudioDeviceTransportTypePCI:
            return "PCI"
        case kAudioDeviceTransportTypeThunderbolt:
            return "Thunderbolt"
        default:
            return "Other"
        }
    }
}
