import CoreAudio
import Foundation
import MBITransportShared

private enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 64
}

private struct Arguments {
    let deviceUID: String
    let deviceName: String
    let sampleRateHint: Double
}

private final class CaptureContext {
    let sharedMemory: UnsafeMutablePointer<MBITransportSharedMemory>
    let streamDescription: AudioStreamBasicDescription
    private var scratchFrames: [Float]
    private var hasLoggedFirstCallback = false

    init(
        sharedMemory: UnsafeMutablePointer<MBITransportSharedMemory>,
        streamDescription: AudioStreamBasicDescription,
        maximumFrameCount: Int
    ) {
        self.sharedMemory = sharedMemory
        self.streamDescription = streamDescription
        self.scratchFrames = Array(repeating: 0, count: max(maximumFrameCount, 4096))
    }

    func handleInput(_ inputData: UnsafePointer<AudioBufferList>?) -> OSStatus {
        guard let inputData else {
            return noErr
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !audioBuffers.isEmpty else {
            return noErr
        }

        if !hasLoggedFirstCallback, let firstBuffer = audioBuffers.first {
            hasLoggedFirstCallback = true
            logLine(
                "Virtual mic capture helper input callback: buffers=\(audioBuffers.count) byteSize=\(firstBuffer.mDataByteSize) data=\(firstBuffer.mData == nil ? "nil" : "present")"
            )
        }

        let frameCount = resolveFrameCount(audioBuffers: audioBuffers)
        guard frameCount > 0 else {
            return noErr
        }

        ensureScratchCapacity(frameCount)
        writeInput(audioBuffers: audioBuffers, frameCount: frameCount)
        MBITransportSetSourceConnected(sharedMemory, 1)
        MBITransportSetRunning(sharedMemory, 1)
        return noErr
    }

    private func resolveFrameCount(audioBuffers: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let firstBuffer = audioBuffers.first else {
            return 0
        }

        let nonInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        if nonInterleaved {
            let bytesPerSample = max(Int(streamDescription.mBitsPerChannel / 8), Int(streamDescription.mBytesPerFrame))
            return bytesPerSample > 0 ? Int(firstBuffer.mDataByteSize) / bytesPerSample : 0
        }

        let bytesPerFrame = max(Int(streamDescription.mBytesPerFrame), 1)
        return Int(firstBuffer.mDataByteSize) / bytesPerFrame
    }

    private func writeInput(audioBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)
        let floatFormat = (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && streamDescription.mBitsPerChannel == 32
        let signedIntegerFormat = (streamDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 && streamDescription.mBitsPerChannel == 16
        let nonInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if floatFormat {
            if nonInterleaved {
                convertNonInterleavedFloatToMono(audioBuffers: audioBuffers, frameCount: frameCount, channelCount: channelCount)
                scratchFrames.withUnsafeBufferPointer { buffer in
                    if let baseAddress = buffer.baseAddress {
                        MBITransportWriteMonoFloat(sharedMemory, baseAddress, UInt32(frameCount))
                    }
                }
            } else if let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                if channelCount <= 1 {
                    MBITransportWriteMonoFloat(sharedMemory, sourcePointer, UInt32(frameCount))
                } else {
                    convertInterleavedFloatToMono(sourcePointer: sourcePointer, frameCount: frameCount, channelCount: channelCount)
                    scratchFrames.withUnsafeBufferPointer { buffer in
                        if let baseAddress = buffer.baseAddress {
                            MBITransportWriteMonoFloat(sharedMemory, baseAddress, UInt32(frameCount))
                        }
                    }
                }
            }
            return
        }

        if signedIntegerFormat {
            if nonInterleaved {
                convertNonInterleavedInt16ToMono(audioBuffers: audioBuffers, frameCount: frameCount, channelCount: channelCount)
                scratchFrames.withUnsafeBufferPointer { buffer in
                    if let baseAddress = buffer.baseAddress {
                        MBITransportWriteMonoFloat(sharedMemory, baseAddress, UInt32(frameCount))
                    }
                }
            } else if let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Int16.self) {
                convertInterleavedInt16ToMono(sourcePointer: sourcePointer, frameCount: frameCount, channelCount: channelCount)
                scratchFrames.withUnsafeBufferPointer { buffer in
                    if let baseAddress = buffer.baseAddress {
                        MBITransportWriteMonoFloat(sharedMemory, baseAddress, UInt32(frameCount))
                    }
                }
            }
        }
    }

    private func ensureScratchCapacity(_ frameCount: Int) {
        if scratchFrames.count < frameCount {
            scratchFrames = Array(repeating: 0, count: frameCount)
        }
    }

    private func convertInterleavedFloatToMono(
        sourcePointer: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        for frameIndex in 0..<frameCount {
            var sampleSum: Float = 0
            let baseIndex = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                sampleSum += sourcePointer[baseIndex + channelIndex]
            }
            scratchFrames[frameIndex] = sampleSum / Float(channelCount)
        }
    }

    private func convertInterleavedInt16ToMono(
        sourcePointer: UnsafePointer<Int16>,
        frameCount: Int,
        channelCount: Int
    ) {
        let scale: Float = 1.0 / 32768.0
        for frameIndex in 0..<frameCount {
            var sampleSum: Float = 0
            let baseIndex = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                sampleSum += Float(sourcePointer[baseIndex + channelIndex]) * scale
            }
            scratchFrames[frameIndex] = sampleSum / Float(channelCount)
        }
    }

    private func convertNonInterleavedFloatToMono(
        audioBuffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int
    ) {
        if channelCount <= 1, let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
            for frameIndex in 0..<frameCount {
                scratchFrames[frameIndex] = sourcePointer[frameIndex]
            }
            return
        }

        for frameIndex in 0..<frameCount {
            var sampleSum: Float = 0
            var contributingChannels = 0
            for bufferIndex in 0..<min(channelCount, audioBuffers.count) {
                guard let sourcePointer = audioBuffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                sampleSum += sourcePointer[frameIndex]
                contributingChannels += 1
            }
            scratchFrames[frameIndex] = contributingChannels > 0 ? sampleSum / Float(contributingChannels) : 0
        }
    }

    private func convertNonInterleavedInt16ToMono(
        audioBuffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int
    ) {
        let scale: Float = 1.0 / 32768.0
        if channelCount <= 1, let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Int16.self) {
            for frameIndex in 0..<frameCount {
                scratchFrames[frameIndex] = Float(sourcePointer[frameIndex]) * scale
            }
            return
        }

        for frameIndex in 0..<frameCount {
            var sampleSum: Float = 0
            var contributingChannels = 0
            for bufferIndex in 0..<min(channelCount, audioBuffers.count) {
                guard let sourcePointer = audioBuffers[bufferIndex].mData?.assumingMemoryBound(to: Int16.self) else {
                    continue
                }
                sampleSum += Float(sourcePointer[frameIndex]) * scale
                contributingChannels += 1
            }
            scratchFrames[frameIndex] = contributingChannels > 0 ? sampleSum / Float(contributingChannels) : 0
        }
    }

    static let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, inClientData in
        guard let inClientData else {
            return noErr
        }

        let context = Unmanaged<CaptureContext>.fromOpaque(inClientData).takeUnretainedValue()
        return context.handleInput(inInputData)
    }
}

private func logLine(_ message: String) {
    fputs("\(message)\n", stdout)
    fflush(stdout)
}

private func logError(_ message: String) {
    fputs("\(message)\n", stderr)
    fflush(stderr)
}

private func parseArguments() -> Arguments? {
    let values = Array(CommandLine.arguments.dropFirst())
    var parsed: [String: String] = [:]
    var index = 0
    while index < values.count {
        let key = values[index]
        let nextIndex = index + 1
        guard key.hasPrefix("--"), nextIndex < values.count else {
            return nil
        }
        parsed[key] = values[nextIndex]
        index += 2
    }

    guard
        let deviceUID = parsed["--device-uid"],
        let deviceName = parsed["--device-name"]
    else {
        return nil
    }

    let sampleRateHint = Double(parsed["--sample-rate"] ?? "") ?? 48_000
    return Arguments(deviceUID: deviceUID, deviceName: deviceName, sampleRateHint: sampleRateHint)
}

private func deviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr else {
        return []
    }

    let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(), count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &ids) == noErr else {
        return []
    }

    return ids
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

private func readDouble(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Float64 = 0
    var propertySize = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &value)
    return status == noErr ? value : nil
}

private func readUInt32(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var propertySize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &value)
    return status == noErr ? value : nil
}

private func readStreamDescription(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value = AudioStreamBasicDescription()
    var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &value)
    return status == noErr ? value : nil
}

private func resolveDeviceID(forUID uid: String) -> AudioDeviceID? {
    for deviceID in deviceIDs() {
        if readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) == uid {
            return deviceID
        }
    }
    return nil
}

private func makeError(_ operation: String, _ status: OSStatus) -> NSError {
    NSError(domain: "VirtualMicCaptureHelper", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed with status \(status)"])
}

private func main() -> ExitCode {
    guard let arguments = parseArguments() else {
        logError("Usage: VirtualMicCaptureHelper --device-uid <uid> --device-name <name> [--sample-rate <hz>]")
        return .usage
    }

    var fileDescriptor: Int32 = -1
    var sharedMemoryPointer: UnsafeMutablePointer<MBITransportSharedMemory>?
    let openStatus = MBITransportOpenSharedMemory(1, &fileDescriptor, &sharedMemoryPointer)
    guard openStatus == 0, let sharedMemoryPointer else {
        logError("Virtual mic capture helper could not open shared memory (errno \(openStatus))")
        return .failure
    }
    defer { MBITransportCloseSharedMemory(fileDescriptor, sharedMemoryPointer) }

    MBITransportSetRunning(sharedMemoryPointer, 0)
    MBITransportSetSourceConnected(sharedMemoryPointer, 0)

    guard let deviceID = resolveDeviceID(forUID: arguments.deviceUID) else {
        logError("Virtual mic capture helper could not resolve device UID \(arguments.deviceUID)")
        return .failure
    }

    let sampleRate = readDouble(
        deviceID: deviceID,
        selector: kAudioDevicePropertyNominalSampleRate
    ) ?? arguments.sampleRateHint
    let streamDescription = readStreamDescription(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput) ?? AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    let bufferFrameSize = Int(readUInt32(deviceID: deviceID, selector: kAudioDevicePropertyBufferFrameSize) ?? 320)

    MBITransportSetSampleRate(sharedMemoryPointer, UInt32(max(8_000, min(192_000, Int(sampleRate.rounded())))))
    logLine(
        "Virtual mic capture helper device format: sampleRate=\(Int(streamDescription.mSampleRate.rounded())) channels=\(streamDescription.mChannelsPerFrame) bits=\(streamDescription.mBitsPerChannel) flags=\(streamDescription.mFormatFlags) bufferFrameSize=\(bufferFrameSize)"
    )

    let context = CaptureContext(
        sharedMemory: sharedMemoryPointer,
        streamDescription: streamDescription,
        maximumFrameCount: bufferFrameSize
    )

    var ioProcID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcID(
        deviceID,
        CaptureContext.ioProc,
        Unmanaged.passUnretained(context).toOpaque(),
        &ioProcID
    )
    guard createStatus == noErr, let ioProcID else {
        logError("Virtual mic capture helper failed to create device IO proc (status \(createStatus))")
        return .failure
    }

    defer {
        AudioDeviceStop(deviceID, ioProcID)
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        MBITransportSetRunning(sharedMemoryPointer, 0)
        MBITransportSetSourceConnected(sharedMemoryPointer, 0)
    }

    let startStatus = AudioDeviceStart(deviceID, ioProcID)
    guard startStatus == noErr else {
        logError("Virtual mic capture helper failed to start device IO proc (status \(startStatus))")
        return .failure
    }

    MBITransportSetRunning(sharedMemoryPointer, 1)
    logLine("Virtual mic capture helper started from '\(arguments.deviceName)' using AudioDevice IOProc at \(Int(sampleRate.rounded())) Hz")
    RunLoop.current.run()
    return .success
}

exit(main().rawValue)
