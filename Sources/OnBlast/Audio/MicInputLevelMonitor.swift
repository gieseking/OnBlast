import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

final class MicInputLevelMonitor: NSObject, @unchecked Sendable {
    var onLog: ((String) -> Void)?
    var onLevelChange: ((Double) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.gieseking.OnBlast.MicInputLevelMonitor")
    private let audioDeviceCatalog = AudioDeviceCatalog()
    private let statusLock = NSLock()

    private var selectedInputDeviceUID = ""
    private var selectedInputDeviceName = ""
    private var audioUnit: AudioUnit?
    private var captureContext: CaptureContext?
    private var currentDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var currentStatus = "No input device"
    private var smoothedLevel: Double = 0
    private var lastEmittedLevel: Double = -1
    private var lastEmission = Date.distantPast

    func configure(selectedInputDeviceUID: String, selectedInputDeviceName: String) {
        self.selectedInputDeviceUID = selectedInputDeviceUID
        self.selectedInputDeviceName = selectedInputDeviceName

        queue.async { [weak self] in
            self?.applyConfigurationOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopCaptureOnQueue(reason: nil)
        }
    }

    private func applyConfigurationOnQueue() {
        let trimmedUID = selectedInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUID.isEmpty else {
            stopCaptureOnQueue(reason: "no input device is selected")
            return
        }

        guard let deviceID = audioDeviceCatalog.deviceID(forUID: trimmedUID) else {
            stopCaptureOnQueue(reason: "the selected input device is not available")
            return
        }

        let resolvedDeviceName = readString(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? selectedInputDeviceName

        if audioUnit != nil, currentDeviceID == deviceID {
            updateStatus("Monitoring \(resolvedDeviceName)")
            return
        }

        stopCaptureOnQueue(reason: nil)

        do {
            try startCaptureOnQueue(deviceID: deviceID, deviceName: resolvedDeviceName)
        } catch {
            stopCaptureOnQueue(reason: "failed to start mic input monitoring: \(error.localizedDescription)")
        }
    }

    private func startCaptureOnQueue(deviceID: AudioDeviceID, deviceName: String) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(domain: "OnBlast", code: -1, userInfo: [NSLocalizedDescriptionKey: "CoreAudio HAL input unit is unavailable"])
        }

        var maybeAudioUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &maybeAudioUnit)
        guard status == noErr, let audioUnit = maybeAudioUnit else {
            throw makeError("AudioComponentInstanceNew", status)
        }

        do {
            var enableInput: UInt32 = 1
            status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableInput,
                UInt32(MemoryLayout<UInt32>.size)
            )
            guard status == noErr else { throw makeError("enable HAL input", status) }

            var disableOutput: UInt32 = 0
            status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disableOutput,
                UInt32(MemoryLayout<UInt32>.size)
            )
            guard status == noErr else { throw makeError("disable HAL output", status) }

            var mutableDeviceID = deviceID
            status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw makeError("select input device", status) }

            let sampleRate = readDouble(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 48_000
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
            status = AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &streamFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard status == noErr else { throw makeError("configure mic indicator format", status) }

            let context = CaptureContext(
                onLevel: { [weak self] level in
                    self?.emitLevel(level)
                },
                onLog: { [weak self] message in
                    self?.log(message)
                }
            )
            captureContext = context

            var callback = AURenderCallbackStruct(
                inputProc: CaptureContext.inputProc,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            guard status == noErr else { throw makeError("register mic indicator callback", status) }

            status = AudioUnitInitialize(audioUnit)
            guard status == noErr else { throw makeError("initialize mic indicator", status) }

            context.audioUnit = audioUnit
            status = AudioOutputUnitStart(audioUnit)
            guard status == noErr else { throw makeError("start mic indicator", status) }

            self.audioUnit = audioUnit
            self.currentDeviceID = deviceID
            self.smoothedLevel = 0
            self.lastEmittedLevel = -1
            self.lastEmission = Date.distantPast
            updateStatus("Monitoring \(deviceName)")
            log("Mic input level monitor started from '\(deviceName)' at \(Int(sampleRate.rounded())) Hz")
        } catch {
            AudioComponentInstanceDispose(audioUnit)
            throw error
        }
    }

    private func stopCaptureOnQueue(reason: String?) {
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }

        audioUnit = nil
        captureContext = nil
        currentDeviceID = AudioDeviceID(kAudioObjectUnknown)
        smoothedLevel = 0
        lastEmittedLevel = -1
        lastEmission = Date.distantPast
        emitLevel(0)

        if let reason {
            updateStatus(reason)
            log("Mic input level monitor stopped because \(reason)")
        } else {
            updateStatus("No input device")
        }
    }

    private func emitLevel(_ level: Double) {
        let clampedLevel = min(max(level, 0), 1)

        statusLock.lock()
        let now = Date()
        let shouldEmit = now.timeIntervalSince(lastEmission) >= 0.05 || abs(clampedLevel - lastEmittedLevel) >= 0.02
        if shouldEmit {
            lastEmission = now
            lastEmittedLevel = clampedLevel
        }
        statusLock.unlock()

        guard shouldEmit else {
            return
        }

        DispatchQueue.main.async {
            self.onLevelChange?(clampedLevel)
        }
    }

    private func updateStatus(_ message: String) {
        currentStatus = message
        DispatchQueue.main.async {
            self.onStatusChange?(message)
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.onLog?(message)
        }
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

        guard status == noErr else {
            return nil
        }

        return value
    }

    private func makeError(_ operation: String, _ status: OSStatus) -> NSError {
        NSError(
            domain: "OnBlast",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed with status \(status)"]
        )
    }
}

private final class CaptureContext {
    let onLevel: (Double) -> Void
    let onLog: (String) -> Void
    let lock = NSLock()
    var audioUnit: AudioUnit?
    var hasLoggedRenderFailure = false
    var smoothedLevel: Double = 0

    init(onLevel: @escaping (Double) -> Void, onLog: @escaping (String) -> Void) {
        self.onLevel = onLevel
        self.onLog = onLog
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
                onLog("Mic input level monitor render failed with status \(renderStatus)")
            }
            return renderStatus
        }

        let renderedFrameCount = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
        guard renderedFrameCount > 0 else {
            return noErr
        }

        let bufferPointer = UnsafeBufferPointer(start: samplePointer, count: renderedFrameCount)
        var totalSquared: Float = 0
        for sample in bufferPointer {
            totalSquared += sample * sample
        }

        let rms = sqrt(totalSquared / Float(max(1, renderedFrameCount)))
        lock.lock()
        smoothedLevel = (smoothedLevel * 0.78) + (Double(rms) * 0.22)
        let displayLevel = min(max(smoothedLevel, 0), 1)
        lock.unlock()

        onLevel(displayLevel)
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
