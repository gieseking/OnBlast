import CoreAudio
import Foundation
import MBITransportShared

final class VirtualMicTransportController: @unchecked Sendable {
    var onLog: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "MediaButtonInterceptor.VirtualMicTransport.session")

    private var selectedInputDeviceUID = ""
    private var selectedInputDeviceName = ""
    private var selectedInputSampleRate: Double = 48_000
    private var selectedInputBufferFrameSize: UInt32 = 512
    private var enabled = false
    private var virtualDeviceDetected = false
    private var muted = false
    private var sharedMemoryFileDescriptor: Int32 = -1
    private var sharedMemoryPointer: UnsafeMutablePointer<MBITransportSharedMemory>?
    private var runningCaptureDeviceUID = ""
    private var runningCaptureSampleRate: Double = 48_000
    private var runningCaptureBufferFrameSize: UInt32 = 512
    private var runningDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var captureContext: CaptureContext?

    func configure(
        enabled: Bool,
        selectedInputDeviceUID: String,
        selectedInputDeviceName: String,
        selectedInputSampleRate: Double,
        virtualDeviceDetected: Bool,
        muted: Bool
    ) {
        self.enabled = enabled
        self.selectedInputDeviceUID = selectedInputDeviceUID
        self.selectedInputDeviceName = selectedInputDeviceName
        self.selectedInputSampleRate = selectedInputSampleRate
        self.selectedInputBufferFrameSize = 512
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

            MBITransportSetMuted(sharedMemoryPointer, muted ? 1 : 0)
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
            MBITransportSetSampleRate(sharedMemoryPointer, normalizedSampleRate(selectedInputSampleRate))
            MBITransportSetBufferFrameSize(sharedMemoryPointer, selectedInputBufferFrameSize)
            MBITransportSetMuted(sharedMemoryPointer, muted ? 1 : 0)
        }

        if ioProcID != nil,
           runningCaptureDeviceUID == selectedInputDeviceUID,
           normalizedSampleRate(runningCaptureSampleRate) == normalizedSampleRate(selectedInputSampleRate),
           runningCaptureBufferFrameSize == selectedInputBufferFrameSize {
            return
        }

        startCaptureOnSessionQueue()
    }

    private func ensureSharedMemoryOnSessionQueue() -> Bool {
        if sharedMemoryPointer != nil {
            return true
        }

        var fileDescriptor: Int32 = -1
        var mappedPointer: UnsafeMutablePointer<MBITransportSharedMemory>?
        let openStatus = MBITransportOpenSharedMemory(1, &fileDescriptor, &mappedPointer)
        guard openStatus == 0, let mappedPointer else {
            log("Virtual mic transport failed to open shared memory at \(String(cString: MBITransportSharedMemoryPath())) (errno \(openStatus))")
            return false
        }

        sharedMemoryFileDescriptor = fileDescriptor
        sharedMemoryPointer = mappedPointer
        MBITransportInitialize(mappedPointer)
        MBITransportSetSampleRate(mappedPointer, normalizedSampleRate(selectedInputSampleRate))
        MBITransportSetBufferFrameSize(mappedPointer, selectedInputBufferFrameSize)
        MBITransportSetMuted(mappedPointer, muted ? 1 : 0)
        MBITransportSetRunning(mappedPointer, 0)
        MBITransportSetSourceConnected(mappedPointer, 0)
        log("Virtual mic transport shared memory opened at \(String(cString: MBITransportSharedMemoryPath()))")
        return true
    }

    private func startCaptureOnSessionQueue() {
        stopCaptureOnSessionQueue(reason: nil)

        guard let sharedMemoryPointer else {
            return
        }

        guard let deviceID = resolveDeviceID(forUID: selectedInputDeviceUID) else {
            MBITransportSetRunning(sharedMemoryPointer, 0)
            MBITransportSetSourceConnected(sharedMemoryPointer, 0)
            log("Virtual mic transport could not resolve CoreAudio input device UID '\(selectedInputDeviceUID)'")
            return
        }

        let sampleRate = readDouble(
            deviceID: deviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) ?? selectedInputSampleRate
        let streamDescription = readStreamDescription(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        ) ?? AudioStreamBasicDescription(
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
        let bufferFrameSize = Int(
            readUInt32(deviceID: deviceID, selector: kAudioDevicePropertyBufferFrameSize) ?? 320
        )
        let resolvedBufferFrameSize = UInt32(max(bufferFrameSize, 1))
        selectedInputBufferFrameSize = resolvedBufferFrameSize

        MBITransportInitialize(sharedMemoryPointer)
        MBITransportSetSampleRate(sharedMemoryPointer, normalizedSampleRate(sampleRate))
        MBITransportSetBufferFrameSize(sharedMemoryPointer, resolvedBufferFrameSize)
        MBITransportSetMuted(sharedMemoryPointer, muted ? 1 : 0)
        MBITransportSetRunning(sharedMemoryPointer, 0)
        MBITransportSetSourceConnected(sharedMemoryPointer, 0)

        let context = CaptureContext(
            sharedMemory: sharedMemoryPointer,
            streamDescription: streamDescription,
            maximumFrameCount: bufferFrameSize
        )
        context.onLog = { [weak self] message in
            self?.log(message)
        }

        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            deviceID,
            CaptureContext.ioProc,
            Unmanaged.passUnretained(context).toOpaque(),
            &ioProcID
        )

        guard createStatus == noErr, let ioProcID else {
            log("Virtual mic transport failed to create CoreAudio IOProc (status \(createStatus))")
            return
        }

        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            log("Virtual mic transport failed to start CoreAudio IOProc (status \(startStatus))")
            return
        }

        self.ioProcID = ioProcID
        self.captureContext = context
        self.runningDeviceID = deviceID
        self.runningCaptureDeviceUID = selectedInputDeviceUID
        self.runningCaptureSampleRate = sampleRate
        self.runningCaptureBufferFrameSize = resolvedBufferFrameSize
        MBITransportSetRunning(sharedMemoryPointer, 1)
        log(
            "Virtual mic transport started CoreAudio capture from '\(selectedInputDeviceName)' " +
            "(sampleRate=\(Int(streamDescription.mSampleRate.rounded())) channels=\(streamDescription.mChannelsPerFrame) " +
            "bits=\(streamDescription.mBitsPerChannel) flags=\(streamDescription.mFormatFlags) bufferFrameSize=\(bufferFrameSize))"
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
            MBITransportSetRunning(sharedMemoryPointer, 0)
            MBITransportSetSourceConnected(sharedMemoryPointer, 0)
        }

        if let reason {
            log("Virtual mic transport stopped because \(reason)")
        }
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
}

private final class CaptureContext {
    var onLog: ((String) -> Void)?

    private let sharedMemory: UnsafeMutablePointer<MBITransportSharedMemory>
    private let streamDescription: AudioStreamBasicDescription
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
            let callbackSummary = "Virtual mic transport input callback: buffers=\(audioBuffers.count) byteSize=\(firstBuffer.mDataByteSize) data=\(firstBuffer.mData == nil ? "nil" : "present")"
            onLog?(callbackSummary)
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
