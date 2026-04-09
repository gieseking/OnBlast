import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

private enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case silence = 2
    case usage = 64
}

private struct Arguments {
    let deviceUID: String
    let deviceName: String
    let duration: TimeInterval
    let outputPath: String
}

private final class CaptureContext {
    let lock = NSLock()
    let sampleRate: Double
    var audioUnit: AudioUnit?
    var samples: [Float] = []
    var hasLoggedRenderFailure = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        samples.reserveCapacity(Int(max(16_000, sampleRate) * 4.0))
    }

    func append(_ source: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: source, count: frameCount))
        lock.unlock()
    }

    func snapshotSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let audioUnit else {
            return noErr
        }

        let frameCount = Int(inNumberFrames)
        guard frameCount > 0 else {
            return noErr
        }

        let samplePointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { samplePointer.deallocate() }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        bufferListPointer.pointee.mNumberBuffers = 1
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        bufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(samplePointer)
        )

        let renderStatus = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            1,
            inNumberFrames,
            bufferListPointer
        )

        guard renderStatus == noErr else {
            if !hasLoggedRenderFailure {
                hasLoggedRenderFailure = true
                fputs("Virtual mic self-test helper HAL render failed with status \(renderStatus)\n", stderr)
            }
            return renderStatus
        }

        let renderedFrameCount = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
        append(UnsafePointer(samplePointer), frameCount: renderedFrameCount)
        return noErr
    }

    static let inputProc: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
        let context = Unmanaged<CaptureContext>.fromOpaque(inRefCon).takeUnretainedValue()
        return context.handleInput(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inNumberFrames: inNumberFrames
        )
    }
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
        let deviceName = parsed["--device-name"],
        let durationString = parsed["--duration"],
        let duration = TimeInterval(durationString),
        let outputPath = parsed["--output"]
    else {
        return nil
    }

    return Arguments(
        deviceUID: deviceUID,
        deviceName: deviceName,
        duration: duration,
        outputPath: outputPath
    )
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

private func readDouble(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Float64 = 0
    var propertySize = UInt32(MemoryLayout<Float64>.size)
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
    NSError(domain: "VirtualMicSelfTestHelper", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed with status \(status)"])
}

private func createAudioUnit(deviceID: AudioDeviceID, sampleRate: Double, context: CaptureContext) throws -> AudioUnit {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    guard let component = AudioComponentFindNext(nil, &description) else {
        throw NSError(domain: "VirtualMicSelfTestHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "CoreAudio HAL input unit is unavailable"])
    }

    var maybeAudioUnit: AudioUnit?
    var status = AudioComponentInstanceNew(component, &maybeAudioUnit)
    guard status == noErr, let audioUnit = maybeAudioUnit else {
        throw makeError("AudioComponentInstanceNew", status)
    }

    do {
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw makeError("enable HAL input", status) }

        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw makeError("disable HAL output", status) }

        var mutableDeviceID = deviceID
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw makeError("select virtual microphone device", status) }

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw makeError("configure HAL capture format", status) }

        var callback = AURenderCallbackStruct(
            inputProc: CaptureContext.inputProc,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw makeError("register HAL input callback", status) }

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else { throw makeError("initialize HAL input unit", status) }

        return audioUnit
    } catch {
        AudioComponentInstanceDispose(audioUnit)
        throw error
    }
}

private func writeRecording(samples: [Float], sampleRate: Double, outputPath: String) throws {
    let outputURL = URL(fileURLWithPath: outputPath)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let frameCount = AVAudioFrameCount(samples.count)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let channelData = buffer.floatChannelData?.pointee else {
        throw NSError(domain: "VirtualMicSelfTestHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate recording buffer"])
    }

    channelData.initialize(from: samples, count: samples.count)
    buffer.frameLength = frameCount

    let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
    try file.write(from: buffer)
}

private func main() -> ExitCode {
    guard let arguments = parseArguments() else {
        fputs("Usage: VirtualMicSelfTestHelper --device-uid <uid> --device-name <name> --duration <seconds> --output <caf>\n", stderr)
        return .usage
    }

    guard let deviceID = resolveDeviceID(forUID: arguments.deviceUID) else {
        fputs("Virtual mic self-test helper could not resolve device UID \(arguments.deviceUID)\n", stderr)
        return .failure
    }

    let sampleRate = readDouble(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 48_000
    let context = CaptureContext(sampleRate: sampleRate)

    do {
        let audioUnit = try createAudioUnit(deviceID: deviceID, sampleRate: sampleRate, context: context)
        context.audioUnit = audioUnit

        print("Virtual mic self-test helper started from '\(arguments.deviceName)' using CoreAudio HAL input at \(Int(sampleRate.rounded())) Hz")

        let startStatus = AudioOutputUnitStart(audioUnit)
        guard startStatus == noErr else {
            throw makeError("AudioOutputUnitStart", startStatus)
        }

        Thread.sleep(forTimeInterval: arguments.duration)

        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        context.audioUnit = nil

        let samples = context.snapshotSamples()
        guard !samples.isEmpty else {
            fputs("Virtual mic self-test recorded no audio\n", stderr)
            return .failure
        }

        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        guard peak >= 0.003 else {
            fputs("Virtual mic self-test captured only silence\n", stderr)
            return .silence
        }

        try writeRecording(samples: samples, sampleRate: sampleRate, outputPath: arguments.outputPath)
        print("Virtual mic self-test helper recorded audio at \(Int(sampleRate.rounded())) Hz")
        return .success
    } catch {
        fputs("Virtual mic self-test helper failed: \(error.localizedDescription)\n", stderr)
        return .failure
    }
}

exit(main().rawValue)
