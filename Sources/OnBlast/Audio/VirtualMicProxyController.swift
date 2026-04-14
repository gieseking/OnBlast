import Foundation

enum VirtualMicProxyError: LocalizedError {
    case bundledDeviceMissing
    case inputDeviceMissing
    case backendNotReady

    var errorDescription: String? {
        switch self {
        case .bundledDeviceMissing:
            return "The bundled virtual microphone device is not installed yet."
        case .inputDeviceMissing:
            return "Choose an input microphone for the virtual mic backend first."
        case .backendNotReady:
            return "The virtual mic transport is enabled, but the virtual microphone device is not ready in Core Audio yet."
        }
    }
}

final class VirtualMicProxyController: MicMuteControlling {
    var onLog: ((String) -> Void)? {
        didSet {
            transportController.onLog = onLog
        }
    }
    var onSpeechDetected: ((MicSpeechDetectionEvent) -> Void)? {
        didSet {
            transportController.onSpeechDetected = onSpeechDetected
        }
    }

    private let transportController = VirtualMicTransportController()
    private var selectedInputDeviceUID = ""
    private var selectedInputDeviceName = ""
    private var bundledVirtualDeviceUID = ""
    private var virtualDeviceDetected = false
    private var enabled = false
    private var muted = false

    func configure(
        enabled: Bool,
        selectedInputDeviceUID: String,
        selectedInputDeviceName: String,
        selectedInputSampleRate: Double,
        speechDetectionEnabled: Bool,
        bundledVirtualDeviceUID: String,
        virtualDeviceDetected: Bool
    ) {
        self.enabled = enabled
        self.selectedInputDeviceUID = selectedInputDeviceUID
        self.selectedInputDeviceName = selectedInputDeviceName
        self.bundledVirtualDeviceUID = bundledVirtualDeviceUID
        self.virtualDeviceDetected = virtualDeviceDetected
        transportController.onLog = onLog
        transportController.configure(
            enabled: enabled,
            selectedInputDeviceUID: selectedInputDeviceUID,
            selectedInputDeviceName: selectedInputDeviceName,
            selectedInputSampleRate: selectedInputSampleRate,
            speechDetectionEnabled: speechDetectionEnabled,
            virtualDeviceDetected: virtualDeviceDetected,
            muted: muted
        )
    }

    func currentState() -> MicState {
        guard isReady else {
            return .unavailable
        }

        guard transportController.isSourceConnected else {
            return .disconnected
        }

        return muted ? .muted : .live
    }

    func setMuted(_ muted: Bool) throws {
        self.muted = muted
        transportController.setMuted(muted)
        if isReady {
            onLog?("Virtual mic proxy mute state restored to \(muted ? "muted" : "live")")
        }
    }

    @discardableResult
    func toggleMute() throws -> Bool {
        guard virtualDeviceDetected else {
            throw VirtualMicProxyError.bundledDeviceMissing
        }

        guard !selectedInputDeviceUID.isEmpty else {
            throw VirtualMicProxyError.inputDeviceMissing
        }

        guard !bundledVirtualDeviceUID.isEmpty else {
            throw VirtualMicProxyError.backendNotReady
        }

        let nextMuted = !muted
        try setMuted(nextMuted)
        onLog?("Virtual mic proxy mute state changed to \(nextMuted ? "muted" : "live")")
        return nextMuted
    }

    var statusDescription: String {
        guard enabled else {
            return "Virtual mic proxy is not active"
        }

        guard virtualDeviceDetected else {
            return "Virtual microphone device not detected"
        }

        guard !selectedInputDeviceUID.isEmpty else {
            return "Choose an input microphone"
        }

        guard transportController.isSourceConnected else {
            return "Selected input microphone is not connected"
        }

        return muted ? "Virtual microphone transport muted" : "Virtual microphone transport live"
    }

    private var isReady: Bool {
        enabled && virtualDeviceDetected && !selectedInputDeviceUID.isEmpty && !bundledVirtualDeviceUID.isEmpty
    }
}
