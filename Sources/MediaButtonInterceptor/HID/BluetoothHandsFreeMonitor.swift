import Foundation
import IOBluetooth

final class BluetoothHandsFreeMonitor: NSObject, @unchecked Sendable {
    var onButtonEvent: ((ButtonEvent) -> Bool)?
    var onLog: ((String) -> Void)?

    private let voiceRecognitionFeatureBit: UInt32 = 1 << 2
    private let retryDelay: TimeInterval = 2.0
    private let connectGracePeriod: TimeInterval = 4.0
    private let connectTimeout: TimeInterval = 5.0

    private var configuration = AppConfiguration()
    private var gateway: InterceptingAudioGateway?
    private var currentCandidate: Candidate?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var retryWorkItem: DispatchWorkItem?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var pendingConnectAddress: String?
    private var connectRequestedAt: Date?
    private var pendingSDPQueryAddress: String?

    func start(configuration: AppConfiguration) {
        stop()

        guard configuration.enableBluetoothHandsFreeMonitor else {
            return
        }

        self.configuration = configuration
        onLog?("Bluetooth HFP monitor started with Bose filter '\(configuration.boseNameFilter)'")
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        attemptConnection(reason: "startup")
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        pendingConnectAddress = nil
        connectRequestedAt = nil
        pendingSDPQueryAddress = nil
        disconnectNotification?.unregister()
        connectNotification?.unregister()
        disconnectNotification = nil
        connectNotification = nil

        gateway?.disconnect()
        gateway = nil
        currentCandidate = nil
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? "Unknown Bluetooth Device"
        performOnMain {
            self.onLog?("Bluetooth device connected: \(name)")
            if self.shouldReactToConnection(named: name) {
                self.attemptConnection(reason: "device connected")
            } else {
                self.onLog?("Bluetooth HFP ignoring non-target device connection: \(name)")
            }
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? "Unknown Bluetooth Device"
        let shouldClearCurrentCandidate = currentCandidate?.address == device.addressString
        performOnMain {
            self.onLog?("Bluetooth device disconnected: \(name)")

            if shouldClearCurrentCandidate {
                self.gateway = nil
                self.currentCandidate = nil
            }
        }
    }

    private func attemptConnection(reason: String) {
        retryWorkItem?.cancel()
        retryWorkItem = nil

        guard let candidate = findCandidate() else {
            onLog?("Bluetooth HFP monitor did not find a connected Bose headset via system_profiler")
            return
        }

        if currentCandidate?.address == candidate.address, let gateway {
            if gateway.isConnected {
                onLog?("Bluetooth HFP gateway is already connected for \(candidate.name)")
                return
            }

            if pendingConnectAddress == candidate.address,
               let connectRequestedAt,
               Date().timeIntervalSince(connectRequestedAt) < connectGracePeriod {
                onLog?("Bluetooth HFP connect is already in progress for \(candidate.name)")
                return
            }

            onLog?("Bluetooth HFP gateway exists for \(candidate.name) but is not connected, rebuilding it")
            gateway.disconnect()
            self.gateway = nil
            pendingConnectAddress = nil
            connectRequestedAt = nil
            connectTimeoutWorkItem?.cancel()
            connectTimeoutWorkItem = nil
        }

        currentCandidate = candidate
        onLog?("Bluetooth HFP candidate (\(reason)): \(candidate.name) at \(candidate.address)")

        guard let device = bluetoothDevice(forAddress: candidate.address) else {
            onLog?("Bluetooth HFP could not create an IOBluetoothDevice for \(candidate.address). Bluetooth permission may still be pending.")
            return
        }

        onLog?("Bluetooth HFP capabilities: handsFreeDevice=\(device.isHandsFreeDevice) handsFreeAudioGateway=\(device.isHandsFreeAudioGateway) connected=\(device.isConnected())")
        if let serviceRecord = device.handsFreeDeviceServiceRecord() {
            let features = serviceRecord.handsFreeSupportedFeatures()
            onLog?("Bluetooth HFP service record supportedFeatures=0x\(String(features, radix: 16))")
        } else {
            onLog?("Bluetooth HFP service record is unavailable for \(candidate.name)")
            if pendingSDPQueryAddress != candidate.address {
                pendingSDPQueryAddress = candidate.address
                let queryResult = device.performSDPQuery(self)
                onLog?("Bluetooth HFP requested SDP query for \(candidate.name) with result \(queryResult)")
            }
        }

        guard let gateway = InterceptingAudioGateway(device: device, delegate: self) else {
            onLog?("Bluetooth HFP could not create an audio gateway for \(candidate.name)")
            return
        }

        gateway.monitor = self
        gateway.deviceNameHint = candidate.name
        gateway.supportedFeatures = voiceRecognitionFeatureBit

        disconnectNotification = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        self.gateway = gateway
        pendingConnectAddress = candidate.address
        connectRequestedAt = Date()
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        gateway.connect()
        onLog?("Bluetooth HFP gateway connect requested for \(candidate.name)")
        scheduleConnectTimeout(for: candidate)
    }

    private func scheduleRetry(reason: String) {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptConnection(reason: reason)
        }
        retryWorkItem = workItem
        onLog?("Bluetooth HFP will retry in \(String(format: "%.1f", retryDelay))s (\(reason))")
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
    }

    private func scheduleConnectTimeout(for candidate: Candidate) {
        connectTimeoutWorkItem?.cancel()
        let address = candidate.address
        let name = candidate.name
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingConnectAddress == address else { return }

            self.onLog?("Bluetooth HFP connect timed out for \(name); no service-level callback arrived within \(String(format: "%.1f", self.connectTimeout))s")
            self.onLog?("Bluetooth HFP cannot observe headset button AT commands until the service-level connection becomes active")
        }
        connectTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout, execute: workItem)
    }

    fileprivate func handleATCommand(_ atCommand: String, gateway: InterceptingAudioGateway) -> Bool {
        let trimmed = atCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let deviceName = gateway.deviceNameHint
        let normalized = trimmed.uppercased()
        guard normalized.contains("BVRA") else {
            performOnMain {
                self.onLog?("Observed Bluetooth HFP AT command from \(deviceName): \(trimmed)")
            }
            return false
        }

        let isDown = !normalized.contains("=0")
        let event = ButtonEvent(
            button: .voiceCommand,
            isDown: isDown,
            isRepeat: false,
            source: .bluetoothHandsFree,
            deviceName: deviceName,
            rawDescription: trimmed
        )

        let shouldConsume = performOnMainSync {
            self.onLog?("Observed Bluetooth HFP AT command from \(deviceName): \(trimmed)")
            return self.onButtonEvent?(event) ?? false
        }
        if shouldConsume {
            performOnMain {
                self.onLog?("Consumed Bluetooth HFP voice-recognition command from \(deviceName)")
            }
            gateway.sendOKResponse()
            return true
        }

        return false
    }

    private func findCandidate() -> Candidate? {
        let filter = configuration.boseNameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = systemProfilerCandidates()
        if candidates.isEmpty {
            onLog?("Bluetooth HFP connected candidates: none")
        } else {
            let summary = candidates
                .map { "\($0.name) [\($0.address)] services=\($0.services)" }
                .joined(separator: " | ")
            onLog?("Bluetooth HFP connected candidates: \(summary)")
        }

        if filter.isEmpty {
            return candidates.first
        }

        return candidates.first { candidate in
            candidate.name.localizedCaseInsensitiveContains(filter)
        }
    }

    private func shouldReactToConnection(named deviceName: String) -> Bool {
        let filter = configuration.boseNameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else {
            return true
        }

        return deviceName.localizedCaseInsensitiveContains(filter)
    }

    private func systemProfilerCandidates() -> [Candidate] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            onLog?("Bluetooth HFP could not run system_profiler: \(error.localizedDescription)")
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            onLog?("Bluetooth HFP system_profiler exited with status \(process.terminationStatus)")
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sections = object["SPBluetoothDataType"] as? [[String: Any]]
        else {
            onLog?("Bluetooth HFP could not parse system_profiler Bluetooth JSON")
            return []
        }

        var candidates: [Candidate] = []

        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else {
                continue
            }

            for entry in connected {
                for (name, payload) in entry {
                    guard let properties = payload as? [String: Any] else {
                        continue
                    }

                    let address = properties["device_address"] as? String ?? ""
                    let services = properties["device_services"] as? String ?? ""
                    guard services.localizedCaseInsensitiveContains("HFP") else {
                        continue
                    }

                    candidates.append(Candidate(name: name, address: address, services: services))
                }
            }
        }

        return candidates
    }

    private func bluetoothDevice(forAddress address: String) -> IOBluetoothDevice? {
        let deviceClass: AnyObject = IOBluetoothDevice.self
        let selector = NSSelectorFromString("deviceWithAddressString:")
        guard deviceClass.responds(to: selector) else {
            onLog?("Bluetooth HFP deviceWithAddressString: selector is unavailable")
            return nil
        }

        guard let unmanaged = deviceClass.perform(selector, with: address) else {
            return nil
        }

        return unmanaged.takeUnretainedValue() as? IOBluetoothDevice
    }

    private func performOnMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            OperationQueue.main.addOperation(work)
        }
    }

    private func performOnMainSync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }

        return DispatchQueue.main.sync(execute: work)
    }
}

extension BluetoothHandsFreeMonitor: IOBluetoothHandsFreeAudioGatewayDelegate, IOBluetoothHandsFreeDelegate {
    @objc func handsFree(_ device: IOBluetoothHandsFreeAudioGateway, redial: NSNumber) {
        performOnMain {
            self.onLog?("Bluetooth HFP redial event observed")
        }
    }

    @objc func handsFree(_ device: IOBluetoothHandsFreeAudioGateway, hangup: NSNumber) {
        performOnMain {
            self.onLog?("Bluetooth HFP hangup event observed")
        }
    }

    @objc func handsFree(_ device: IOBluetoothHandsFree, connected status: NSNumber) {
        let statusValue = status.intValue
        performOnMain {
            self.onLog?("Bluetooth HFP service-level connection result: \(status)")
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            self.pendingConnectAddress = nil
            self.connectRequestedAt = nil
            guard statusValue == kIOReturnSuccess else {
                self.gateway = nil
                self.scheduleRetry(reason: "connect failed")
                return
            }

            self.onLog?("Bluetooth HFP service-level connection is active")
        }
    }

    @objc func handsFree(_ device: IOBluetoothHandsFree, disconnected status: NSNumber) {
        performOnMain {
            self.onLog?("Bluetooth HFP disconnected with status \(status)")
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            self.pendingConnectAddress = nil
            self.connectRequestedAt = nil
            self.gateway = nil
            self.scheduleRetry(reason: "disconnected")
        }
    }

    @objc func handsFree(_ device: IOBluetoothHandsFree, scoConnectionOpened status: NSNumber) {
        performOnMain {
            self.onLog?("Bluetooth HFP SCO connection opened with status \(status)")
        }
    }

    @objc func handsFree(_ device: IOBluetoothHandsFree, scoConnectionClosed status: NSNumber) {
        performOnMain {
            self.onLog?("Bluetooth HFP SCO connection closed with status \(status)")
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        let name = device.name ?? "Unknown Bluetooth Device"
        let address = device.addressString ?? ""
        let serviceRecordFeaturesHex: String? = {
            guard status == kIOReturnSuccess,
                  let serviceRecord = device.handsFreeDeviceServiceRecord() else {
                return nil
            }

            let features = serviceRecord.handsFreeSupportedFeatures()
            return "0x\(String(features, radix: 16))"
        }()
        performOnMain {
            self.onLog?("Bluetooth HFP SDP query completed for \(name) with status \(status)")
            if self.pendingSDPQueryAddress == address {
                self.pendingSDPQueryAddress = nil
            }

            if status == kIOReturnSuccess {
                if let serviceRecordFeaturesHex {
                    self.onLog?("Bluetooth HFP service record after SDP query supportedFeatures=\(serviceRecordFeaturesHex)")
                } else {
                    self.onLog?("Bluetooth HFP service record is still unavailable after SDP query for \(name)")
                }
            }
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        let name = device.name ?? "Unknown Bluetooth Device"
        performOnMain {
            self.onLog?("Bluetooth baseband connection callback for \(name) returned status \(status)")
        }
    }
}

private struct Candidate: Equatable {
    let name: String
    let address: String
    let services: String
}

private final class InterceptingAudioGateway: IOBluetoothHandsFreeAudioGateway {
    weak var monitor: BluetoothHandsFreeMonitor?
    var deviceNameHint = "Bluetooth HFP Device"

    override func process(atCommand: String!) {
        if monitor?.handleATCommand(atCommand ?? "", gateway: self) == true {
            return
        }

        super.process(atCommand: atCommand)
    }
}
