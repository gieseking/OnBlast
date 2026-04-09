import AVFoundation
import CoreAudio
import Foundation

struct MicSpeechDetectionEvent {
    let sourceDescription: String
    let level: Float?
}

final class MicSpeechActivityMonitor: @unchecked Sendable {
    var onLog: ((String) -> Void)?
    var onSpeechDetected: ((MicSpeechDetectionEvent) -> Void)?

    private let engine = AVAudioEngine()
    private let detectionThreshold: Float = 0.015
    private let requiredConsecutiveBuffers = 2
    private let eventCooldown: TimeInterval = 1.5
    private let vadPollingInterval: TimeInterval = 0.2
    private let stateQueue = DispatchQueue(label: "com.gieseking.OnBlast.MicSpeechActivityMonitor")
    private let stateLock = NSLock()

    private var enabled = false
    private var consecutiveBuffersOverThreshold = 0
    private var suppressDetectionUntil = Date.distantPast
    private var isRunning = false
    private var audioTapRestartQueued = false
    private var audioEngineConfigurationObserver: NSObjectProtocol?
    private var vadTimer: DispatchSourceTimer?
    private var vadEnabledDevice: AudioDeviceID?
    private var vadSupported = false
    private var lastVoiceActivityState: UInt32 = 0

    func start(enabled: Bool) {
        stop()
        self.enabled = enabled

        guard enabled else {
            return
        }

        registerAudioEngineConfigurationObserver()
        startVoiceActivityDetectionPolling()
        startAudioTapFallback()
    }

    func stop() {
        enabled = false
        unregisterAudioEngineConfigurationObserver()
        stopVoiceActivityDetectionPolling()
        stopAudioTapFallback()
        consecutiveBuffersOverThreshold = 0
        suppressDetectionUntil = Date.distantPast
        audioTapRestartQueued = false
    }

    func suppressDetection(for duration: TimeInterval) {
        stateLock.lock()
        suppressDetectionUntil = Date().addingTimeInterval(duration)
        consecutiveBuffersOverThreshold = 0
        stateLock.unlock()
    }

    private func startAudioTapFallback() {
        engine.stop()
        engine.reset()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.channelCount > 0 else {
            emitLog("Muted speech reminder audio tap could not start because no input channels are available")
            return
        }

        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: hardwareFormat.channelCount,
            interleaved: false
        ) ?? hardwareFormat

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        do {
            try engine.start()
            isRunning = true
            emitLog("Muted speech reminder audio tap started")
        } catch {
            inputNode.removeTap(onBus: 0)
            emitLog("Muted speech reminder audio tap failed to start: \(error.localizedDescription)")
        }
    }

    private func stopAudioTapFallback() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        isRunning = false
    }

    private func startVoiceActivityDetectionPolling() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: vadPollingInterval)
        timer.setEventHandler { [weak self] in
            self?.pollVoiceActivityDetection()
        }
        vadTimer = timer
        timer.resume()
        emitLog("Muted speech reminder voice activity monitor started")
    }

    private func stopVoiceActivityDetectionPolling() {
        vadTimer?.cancel()
        vadTimer = nil
        vadEnabledDevice = nil
        vadSupported = false
        lastVoiceActivityState = 0
    }

    private func pollVoiceActivityDetection() {
        if enabled, !engine.isRunning {
            queueAudioTapRestartIfNeeded(reason: "audio engine is not running")
        }

        guard let device = try? defaultInputDevice() else {
            if vadEnabledDevice != nil {
                vadEnabledDevice = nil
                vadSupported = false
                lastVoiceActivityState = 0
                emitLog("Muted speech reminder voice activity monitor lost the default input device")
            }
            return
        }

        if device != vadEnabledDevice {
            configureVoiceActivityDetection(for: device)
        }

        guard vadSupported else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard let state = try? readUInt32(device: device, address: &address) else {
            return
        }

        defer {
            lastVoiceActivityState = state
        }

        guard state != 0, lastVoiceActivityState == 0 else {
            return
        }

        triggerSpeechDetected(
            sourceDescription: "device voice activity detection",
            level: nil
        )
    }

    private func configureVoiceActivityDetection(for device: AudioDeviceID) {
        vadEnabledDevice = device
        vadSupported = false
        lastVoiceActivityState = 0

        var enableAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var stateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard
            AudioObjectHasProperty(device, &enableAddress),
            AudioObjectHasProperty(device, &stateAddress)
        else {
            emitLog("Muted speech reminder voice activity detection is unavailable on the current input device; falling back to the audio tap")
            return
        }

        do {
            _ = try setUInt32IfPossible(device: device, address: &enableAddress, value: 1)
            _ = try readUInt32(device: device, address: &stateAddress)
            vadSupported = true
            emitLog("Muted speech reminder voice activity detection is active on the current input device")
        } catch {
            emitLog("Muted speech reminder voice activity detection could not be enabled: \(error.localizedDescription)")
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let isSuppressed = Date() < suppressDetectionUntil
        stateLock.unlock()

        guard !isSuppressed else {
            return
        }

        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var totalSquared: Float = 0
        for channelIndex in 0..<channelCount {
            let samples = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = samples[frameIndex]
                totalSquared += sample * sample
            }
        }

        let sampleCount = max(1, frameCount * channelCount)
        let rms = sqrt(totalSquared / Float(sampleCount))

        if rms >= detectionThreshold {
            stateLock.lock()
            consecutiveBuffersOverThreshold += 1
            let updatedCount = consecutiveBuffersOverThreshold
            stateLock.unlock()
            if updatedCount < requiredConsecutiveBuffers {
                return
            }
        } else {
            stateLock.lock()
            consecutiveBuffersOverThreshold = 0
            stateLock.unlock()
            return
        }

        triggerSpeechDetected(sourceDescription: "audio tap level monitor", level: rms)
    }

    private func triggerSpeechDetected(sourceDescription: String, level: Float?) {
        stateLock.lock()
        guard Date() >= suppressDetectionUntil else {
            stateLock.unlock()
            return
        }

        consecutiveBuffersOverThreshold = 0
        suppressDetectionUntil = Date().addingTimeInterval(eventCooldown)
        stateLock.unlock()

        let event = MicSpeechDetectionEvent(sourceDescription: sourceDescription, level: level)
        DispatchQueue.main.async {
            self.onSpeechDetected?(event)
        }
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

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw MicControllerError.noInputDevice
        }

        return deviceID
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

    private func emitLog(_ message: String) {
        DispatchQueue.main.async {
            self.onLog?(message)
        }
    }

    private func registerAudioEngineConfigurationObserver() {
        audioEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queueAudioTapRestartIfNeeded(reason: "audio engine configuration changed")
        }
    }

    private func unregisterAudioEngineConfigurationObserver() {
        if let observer = audioEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
            audioEngineConfigurationObserver = nil
        }
    }

    private func queueAudioTapRestartIfNeeded(reason: String) {
        stateLock.lock()
        guard enabled, !audioTapRestartQueued else {
            stateLock.unlock()
            return
        }

        audioTapRestartQueued = true
        stateLock.unlock()

        emitLog("Muted speech reminder audio tap is restarting because \(reason)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopAudioTapFallback()
            if self.enabled {
                self.startAudioTapFallback()
            }
            self.stateLock.lock()
            self.audioTapRestartQueued = false
            self.stateLock.unlock()
        }
    }
}
