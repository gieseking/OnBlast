import CoreAudio
import Foundation
import OBTransportShared

final class VirtualMicTransportController: @unchecked Sendable {
    private static let transportSampleRate: Double = 48_000
    private static let transportBufferFrameSize: UInt32 = 512

    var onLog: ((String) -> Void)?
    var onSpeechDetected: ((MicSpeechDetectionEvent) -> Void)?

    private let sessionQueue = DispatchQueue(label: "OnBlast.VirtualMicTransport.session")
    private let stateLock = NSLock()

    private var selectedInputDeviceUID = ""
    private var selectedInputDeviceName = ""
    private var selectedInputSampleRate: Double = 48_000
    private var selectedInputBufferFrameSize: UInt32 = 512
    private var speechDetectionEnabled = false
    private var enabled = false
    private var virtualDeviceDetected = false
    private var muted = false
    private var sharedMemoryFileDescriptor: Int32 = -1
    private var sharedMemoryPointer: UnsafeMutablePointer<OBTransportSharedMemory>?
    private var runningCaptureDeviceUID = ""
    private var runningCaptureSampleRate: Double = 48_000
    private var runningCaptureBufferFrameSize: UInt32 = 512
    private var runningDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var captureContext: CaptureContext?
    private var sourceConnected = false

    var isSourceConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sourceConnected
    }

    func configure(
        enabled: Bool,
        selectedInputDeviceUID: String,
        selectedInputDeviceName: String,
        selectedInputSampleRate: Double,
        speechDetectionEnabled: Bool,
        virtualDeviceDetected: Bool,
        muted: Bool
    ) {
        self.enabled = enabled
        self.selectedInputDeviceUID = selectedInputDeviceUID
        self.selectedInputDeviceName = selectedInputDeviceName
        self.selectedInputSampleRate = selectedInputSampleRate
        self.speechDetectionEnabled = speechDetectionEnabled
        self.virtualDeviceDetected = virtualDeviceDetected
        self.muted = muted

        sessionQueue.async { [weak self] in
            self?.applyConfigurationOnSessionQueue()
        }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        sessionQueue.async { [weak self] in
            guard let self, let sharedMemoryPointer = self.sharedMemoryPointer else {
                return
            }

            OBTransportSetMuted(sharedMemoryPointer, muted ? 1 : 0)
        }
    }

    private func applyConfigurationOnSessionQueue() {
        guard enabled, virtualDeviceDetected else {
            stopCaptureOnSessionQueue(reason: enabled ? "virtual device is not detected" : "virtual mic proxy backend is disabled")
            return
        }

        guard !selectedInputDeviceUID.isEmpty || !selectedInputDeviceName.isEmpty else {
            stopCaptureOnSessionQueue(reason: "no physical input device is selected for the virtual mic transport")
            return
        }

        guard ensureSharedMemoryOnSessionQueue() else {
            stopCaptureOnSessionQueue(reason: "shared transport memory is unavailable")
            return
        }

        if let sharedMemoryPointer {
            OBTransportSetSampleRate(sharedMemoryPointer, normalizedSampleRate(Self.transportSampleRate))
            OBTransportSetBufferFrameSize(sharedMemoryPointer, Self.transportBufferFrameSize)
            OBTransportSetMuted(sharedMemoryPointer, muted ? 1 : 0)
        }

        captureContext?.speechDetectionEnabled = speechDetectionEnabled

        if ioProcID != nil,
           runningCaptureDeviceUID == selectedInputDeviceUID,
           normalizedSampleRate(runningCaptureSampleRate) == normalizedSampleRate(selectedInputSampleRate),
           runningCaptureBufferFrameSize == selectedInputBufferFrameSize,
           resolveDeviceID(forUID: selectedInputDeviceUID) != nil {
            return
        }

        startCaptureOnSessionQueue()
    }

    private func ensureSharedMemoryOnSessionQueue() -> Bool {
        if sharedMemoryPointer != nil {
            return true
        }

        var fileDescriptor: Int32 = -1
        var mappedPointer: UnsafeMutablePointer<OBTransportSharedMemory>?
        let openStatus = OBTransportOpenSharedMemory(1, &fileDescriptor, &mappedPointer)
        guard openStatus == 0, let mappedPointer else {
            log("Virtual mic transport failed to open shared memory at \(String(cString: OBTransportSharedMemoryPath())) (errno \(openStatus))")
            return false
        }

        sharedMemoryFileDescriptor = fileDescriptor
        sharedMemoryPointer = mappedPointer
        OBTransportInitialize(mappedPointer)
        OBTransportSetSampleRate(mappedPointer, normalizedSampleRate(Self.transportSampleRate))
        OBTransportSetBufferFrameSize(mappedPointer, Self.transportBufferFrameSize)
        OBTransportSetMuted(mappedPointer, muted ? 1 : 0)
        OBTransportSetRunning(mappedPointer, 0)
        OBTransportSetSourceConnected(mappedPointer, 0)
        setSourceConnected(false)
        log("Virtual mic transport shared memory opened at \(String(cString: OBTransportSharedMemoryPath()))")
        return true
    }

    private func startCaptureOnSessionQueue() {
        stopCaptureOnSessionQueue(reason: nil)

        guard let sharedMemoryPointer else {
            return
        }

        guard let deviceID = resolveDeviceID(forUID: selectedInputDeviceUID) else {
            OBTransportSetRunning(sharedMemoryPointer, 0)
            OBTransportSetSourceConnected(sharedMemoryPointer, 0)
            setSourceConnected(false)
            log("Virtual mic transport could not resolve CoreAudio input device UID '\(selectedInputDeviceUID)'")
            return
        }

        let inputSampleRate = readDouble(
            deviceID: deviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) ?? selectedInputSampleRate
        let streamDescription = readStreamDescription(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        ) ?? AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let bufferFrameSize = Int(
            readUInt32(deviceID: deviceID, selector: kAudioDevicePropertyBufferFrameSize) ?? 320
        )
        let resolvedBufferFrameSize = UInt32(max(bufferFrameSize, 1))
        selectedInputBufferFrameSize = resolvedBufferFrameSize

        OBTransportInitialize(sharedMemoryPointer)
        OBTransportSetSampleRate(sharedMemoryPointer, normalizedSampleRate(Self.transportSampleRate))
        OBTransportSetBufferFrameSize(sharedMemoryPointer, Self.transportBufferFrameSize)
        OBTransportSetMuted(sharedMemoryPointer, muted ? 1 : 0)
        OBTransportSetRunning(sharedMemoryPointer, 0)
        OBTransportSetSourceConnected(sharedMemoryPointer, 0)
        setSourceConnected(false)

        let context = CaptureContext(
            sharedMemory: sharedMemoryPointer,
            streamDescription: streamDescription,
            outputSampleRate: Self.transportSampleRate,
            maximumFrameCount: bufferFrameSize
        )
        context.onLog = { [weak self] message in
            self?.log(message)
        }
        context.onSpeechDetected = { [weak self] event in
            self?.emitSpeechDetected(event)
        }
        context.onSourceConnectionChanged = { [weak self] connected in
            self?.setSourceConnected(connected)
        }
        context.speechDetectionEnabled = speechDetectionEnabled

        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            deviceID,
            CaptureContext.ioProc,
            Unmanaged.passUnretained(context).toOpaque(),
            &ioProcID
        )

        guard createStatus == noErr, let ioProcID else {
            setSourceConnected(false)
            log("Virtual mic transport failed to create CoreAudio IOProc (status \(createStatus))")
            return
        }

        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            setSourceConnected(false)
            log("Virtual mic transport failed to start CoreAudio IOProc (status \(startStatus))")
            return
        }

        self.ioProcID = ioProcID
        self.captureContext = context
        self.runningDeviceID = deviceID
        self.runningCaptureDeviceUID = selectedInputDeviceUID
        self.runningCaptureSampleRate = inputSampleRate
        self.runningCaptureBufferFrameSize = resolvedBufferFrameSize
        OBTransportSetRunning(sharedMemoryPointer, 1)
        setSourceConnected(true)
        log(
            "Virtual mic transport started CoreAudio capture from '\(selectedInputDeviceName)' " +
            "(sourceSampleRate=\(Int(streamDescription.mSampleRate.rounded())) transportSampleRate=\(Int(Self.transportSampleRate.rounded())) " +
            "channels=\(streamDescription.mChannelsPerFrame) bits=\(streamDescription.mBitsPerChannel) flags=\(streamDescription.mFormatFlags) " +
            "sourceBufferFrameSize=\(bufferFrameSize) transportBufferFrameSize=\(Self.transportBufferFrameSize))"
        )
    }

    private func stopCaptureOnSessionQueue(reason: String?) {
        if let ioProcID, runningDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(runningDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(runningDeviceID, ioProcID)
        }

        ioProcID = nil
        captureContext = nil
        runningDeviceID = AudioDeviceID(kAudioObjectUnknown)
        runningCaptureDeviceUID = ""
        runningCaptureSampleRate = 48_000
        runningCaptureBufferFrameSize = 512

        if let sharedMemoryPointer {
            OBTransportSetRunning(sharedMemoryPointer, 0)
            OBTransportSetSourceConnected(sharedMemoryPointer, 0)
        }
        setSourceConnected(false)

        if let reason {
            log("Virtual mic transport stopped because \(reason)")
        }
    }

    private func setSourceConnected(_ connected: Bool) {
        stateLock.lock()
        sourceConnected = connected
        stateLock.unlock()
    }

    private func resolveDeviceID(forUID uid: String) -> AudioDeviceID? {
        let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUID.isEmpty else {
            return nil
        }

        for deviceID in deviceIDs() {
            if readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) == trimmedUID {
                return deviceID
            }
        }

        return nil
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

    private func readDouble(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Double? {
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

    private func readUInt32(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
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

    private func readStreamDescription(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> AudioStreamBasicDescription? {
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

    private func normalizedSampleRate(_ sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return 48_000
        }

        return UInt32(max(8_000, min(192_000, Int(sampleRate.rounded()))))
    }

    private func log(_ message: String) {
        let onLog = self.onLog
        DispatchQueue.main.async {
            onLog?(message)
        }
    }

    private func emitSpeechDetected(_ event: MicSpeechDetectionEvent) {
        let onSpeechDetected = self.onSpeechDetected
        DispatchQueue.main.async {
            onSpeechDetected?(event)
        }
    }
}

private final class CaptureContext {
    var onLog: ((String) -> Void)?
    var onSpeechDetected: ((MicSpeechDetectionEvent) -> Void)?
    var onSourceConnectionChanged: ((Bool) -> Void)?
    var speechDetectionEnabled = false

    private let sharedMemory: UnsafeMutablePointer<OBTransportSharedMemory>
    private let streamDescription: AudioStreamBasicDescription
    private let outputSampleRate: Double
    private let speechDetectionThreshold: Float = 0.015
    private let requiredConsecutiveBuffers = 2
    private let speechEventCooldown: TimeInterval = 1.5
    private var monoScratchFrames: [Float]
    private var outputScratchFrames: [Float]
    private var resampleSourcePosition: Double = 0
    private var hasLoggedFirstCallback = false
    private var consecutiveBuffersOverThreshold = 0
    private var suppressSpeechDetectionUntil = Date.distantPast

    init(
        sharedMemory: UnsafeMutablePointer<OBTransportSharedMemory>,
        streamDescription: AudioStreamBasicDescription,
        outputSampleRate: Double,
        maximumFrameCount: Int
    ) {
        self.sharedMemory = sharedMemory
        self.streamDescription = streamDescription
        self.outputSampleRate = outputSampleRate
        self.monoScratchFrames = Array(repeating: 0, count: max(maximumFrameCount, 4096))
        self.outputScratchFrames = Array(repeating: 0, count: max(maximumFrameCount * 4, 4096))
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
            let callbackSummary = "Virtual mic transport input callback: buffers=\(audioBuffers.count) byteSize=\(firstBuffer.mDataByteSize) data=\(firstBuffer.mData == nil ? "nil" : "present")"
            onLog?(callbackSummary)
        }

        let frameCount = resolveFrameCount(audioBuffers: audioBuffers)
        guard frameCount > 0 else {
            return noErr
        }

        ensureScratchCapacity(frameCount)
        writeInput(audioBuffers: audioBuffers, frameCount: frameCount)
        let outputFrameCount = resampleIfNeeded(inputFrameCount: frameCount)
        outputScratchFrames.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            OBTransportWriteMonoFloat(sharedMemory, baseAddress, UInt32(outputFrameCount))
        }
        detectSpeech(audioBuffers: audioBuffers, frameCount: frameCount)
        OBTransportSetSourceConnected(sharedMemory, 1)
        OBTransportSetRunning(sharedMemory, 1)
        onSourceConnectionChanged?(true)
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
            } else if let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                convertInterleavedFloatToMono(sourcePointer: sourcePointer, frameCount: frameCount, channelCount: channelCount)
            }
            return
        }

        if signedIntegerFormat {
            if nonInterleaved {
                convertNonInterleavedInt16ToMono(audioBuffers: audioBuffers, frameCount: frameCount, channelCount: channelCount)
            } else if let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Int16.self) {
                convertInterleavedInt16ToMono(sourcePointer: sourcePointer, frameCount: frameCount, channelCount: channelCount)
            }
        }
    }

    private func ensureScratchCapacity(_ frameCount: Int) {
        if monoScratchFrames.count < frameCount {
            monoScratchFrames = Array(repeating: 0, count: frameCount)
        }

        let sourceSampleRate = max(streamDescription.mSampleRate, 1)
        let requiredOutputFrames = Int(ceil(Double(frameCount) * (outputSampleRate / sourceSampleRate))) + 4
        if outputScratchFrames.count < requiredOutputFrames {
            outputScratchFrames = Array(repeating: 0, count: requiredOutputFrames)
        }
    }

    private func resampleIfNeeded(inputFrameCount: Int) -> Int {
        guard inputFrameCount > 0 else {
            return 0
        }

        let sourceSampleRate = max(streamDescription.mSampleRate, 1)
        guard abs(sourceSampleRate - outputSampleRate) > 0.5 else {
            outputScratchFrames[0..<inputFrameCount] = monoScratchFrames[0..<inputFrameCount]
            return inputFrameCount
        }

        let sourceStep = sourceSampleRate / outputSampleRate
        var outputFrameCount = 0
        var sourcePosition = resampleSourcePosition

        while sourcePosition < Double(inputFrameCount) {
            let lowerIndex = min(max(Int(sourcePosition.rounded(.down)), 0), inputFrameCount - 1)
            let upperIndex = min(lowerIndex + 1, inputFrameCount - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            let lowerSample = monoScratchFrames[lowerIndex]
            let upperSample = monoScratchFrames[upperIndex]
            outputScratchFrames[outputFrameCount] = lowerSample + ((upperSample - lowerSample) * fraction)
            outputFrameCount += 1
            sourcePosition += sourceStep
        }

        resampleSourcePosition = max(sourcePosition - Double(inputFrameCount), 0)
        return outputFrameCount
    }

    private func detectSpeech(audioBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard speechDetectionEnabled, onSpeechDetected != nil else {
            return
        }

        let now = Date()
        guard now >= suppressSpeechDetectionUntil else {
            return
        }

        let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)
        let floatFormat = (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && streamDescription.mBitsPerChannel == 32
        let signedIntegerFormat = (streamDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 && streamDescription.mBitsPerChannel == 16
        let nonInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var totalSquared: Float = 0
        var sampleCount = 0

        if floatFormat {
            if nonInterleaved {
                for bufferIndex in 0..<min(channelCount, audioBuffers.count) {
                    guard let sourcePointer = audioBuffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                        continue
                    }
                    for frameIndex in 0..<frameCount {
                        let sample = sourcePointer[frameIndex]
                        totalSquared += sample * sample
                    }
                    sampleCount += frameCount
                }
            } else if let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                let totalSampleCount = frameCount * channelCount
                for sampleIndex in 0..<totalSampleCount {
                    let sample = sourcePointer[sampleIndex]
                    totalSquared += sample * sample
                }
                sampleCount = totalSampleCount
            }
        } else if signedIntegerFormat {
            let scale: Float = 1.0 / 32768.0
            if nonInterleaved {
                for bufferIndex in 0..<min(channelCount, audioBuffers.count) {
                    guard let sourcePointer = audioBuffers[bufferIndex].mData?.assumingMemoryBound(to: Int16.self) else {
                        continue
                    }
                    for frameIndex in 0..<frameCount {
                        let sample = Float(sourcePointer[frameIndex]) * scale
                        totalSquared += sample * sample
                    }
                    sampleCount += frameCount
                }
            } else if let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Int16.self) {
                let totalSampleCount = frameCount * channelCount
                for sampleIndex in 0..<totalSampleCount {
                    let sample = Float(sourcePointer[sampleIndex]) * scale
                    totalSquared += sample * sample
                }
                sampleCount = totalSampleCount
            }
        }

        guard sampleCount > 0 else {
            return
        }

        let rms = sqrt(totalSquared / Float(sampleCount))
        if rms >= speechDetectionThreshold {
            consecutiveBuffersOverThreshold += 1
        } else {
            consecutiveBuffersOverThreshold = 0
            return
        }

        guard consecutiveBuffersOverThreshold >= requiredConsecutiveBuffers else {
            return
        }

        consecutiveBuffersOverThreshold = 0
        suppressSpeechDetectionUntil = now.addingTimeInterval(speechEventCooldown)
        onSpeechDetected?(MicSpeechDetectionEvent(sourceDescription: "virtual mic proxy transport", level: rms))
    }

    private func convertInterleavedFloatToMono(
        sourcePointer: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        if channelCount <= 1 {
            monoScratchFrames.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.update(from: sourcePointer, count: frameCount)
            }
            return
        }

        for frameIndex in 0..<frameCount {
            var sampleSum: Float = 0
            let baseIndex = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                sampleSum += sourcePointer[baseIndex + channelIndex]
            }
            monoScratchFrames[frameIndex] = sampleSum / Float(channelCount)
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
            monoScratchFrames[frameIndex] = sampleSum / Float(channelCount)
        }
    }

    private func convertNonInterleavedFloatToMono(
        audioBuffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int
    ) {
        if channelCount <= 1, let sourcePointer = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
            monoScratchFrames.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.update(from: sourcePointer, count: frameCount)
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
            monoScratchFrames[frameIndex] = contributingChannels > 0 ? sampleSum / Float(contributingChannels) : 0
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
                monoScratchFrames[frameIndex] = Float(sourcePointer[frameIndex]) * scale
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
            monoScratchFrames[frameIndex] = contributingChannels > 0 ? sampleSum / Float(contributingChannels) : 0
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
