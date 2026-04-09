import Foundation

final class UnifiedSystemLogMonitor: @unchecked Sendable {
    var onButtonEvent: ((ButtonEvent) -> Bool)?
    var onLog: ((String) -> Void)?

    private let interestingProcesses = [
        "bluetoothd",
        "mediaremoted",
        "assistantd",
        "Siri",
        "suggestd"
    ]

    private var process: Process?
    private var outputHandle: FileHandle?
    private var bufferedData = Data()
    private var actionTerms: [String] = []
    private var suppressUntilByButton: [ButtonIdentifier: Date] = [:]

    private let voiceCommandSuppressionInterval: TimeInterval = 0.8
    private let actionSuppressionInterval: TimeInterval = 0.45

    func start(configuration: AppConfiguration) {
        stop()

        guard shouldEnable(for: configuration) else {
            return
        }

        actionTerms = buildActionTerms(configuration: configuration)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style", "compact",
            "--level", "debug",
            "--predicate", predicate
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.onLog?("Unified system log stream exited with status \(process.terminationStatus)")
            }
        }

        do {
            try process.run()
            self.process = process
            outputHandle = handle
            log("Unified system action log stream started for Bluetooth / MediaRemote / Siri diagnostics")
        } catch {
            log("Failed to start unified system action log stream: \(error.localizedDescription)")
        }
    }

    func stop() {
        outputHandle?.readabilityHandler = nil
        outputHandle = nil

        if let process, process.isRunning {
            process.terminate()
        }

        self.process = nil
        bufferedData.removeAll(keepingCapacity: false)
        actionTerms.removeAll(keepingCapacity: false)
        suppressUntilByButton.removeAll(keepingCapacity: false)
    }

    private func consume(_ data: Data) {
        bufferedData.append(data)

        while let newlineRange = bufferedData.firstRange(of: Data([0x0A])) {
            let lineData = bufferedData.subdata(in: bufferedData.startIndex..<newlineRange.lowerBound)
            bufferedData.removeSubrange(bufferedData.startIndex..<newlineRange.upperBound)

            guard
                let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !line.isEmpty,
                shouldLog(line)
            else {
                continue
            }

            log("Unified system log: \(line)")
            handlePotentialButtonEvent(from: line)
        }
    }

    private func shouldEnable(for configuration: AppConfiguration) -> Bool {
        configuration.enableBluetoothHandsFreeMonitor ||
        configuration.enablePrivateMediaRemoteBridge ||
        configuration.enableSiriActivationFallback
    }

    private func buildActionTerms(configuration: AppConfiguration) -> [String] {
        let terms = [
            "received set voice command event",
            "voice command - activating siri",
            "sirincactionbvra1",
            "invoking action 'sirincactionbvra1'",
            "sirincactionbvra1 - bluetoothhfp",
            "processatcommand",
            "processapplecommand",
            "processappleevent",
            "handle siri appear",
            "handle siri disappear",
            "siriappear",
            "siridisappear",
            "mediaremote command",
            "remote command",
            "toggle play/pause",
            "play/pause",
            "playpause",
            "next track",
            "nexttrack",
            "previous track",
            "previoustrack",
            "volume up",
            "volume down",
            "mute",
            "bvra"
        ]

        _ = configuration

        return Array(Set(terms))
    }

    private func shouldLog(_ line: String) -> Bool {
        let lowercasedLine = line.lowercased()
        return actionTerms.contains(where: { lowercasedLine.contains($0) })
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.onLog?(message)
        }
    }

    private func handlePotentialButtonEvent(from line: String) {
        if EventInjectionGuard.shared.shouldIgnoreSyntheticEvents {
            return
        }

        let lowercasedLine = line.lowercased()

        guard let button = decodeButton(from: lowercasedLine) else {
            return
        }

        let now = Date()
        let suppressionDeadline = suppressUntilByButton[button] ?? .distantPast
        guard now >= suppressionDeadline else {
            return
        }

        suppressUntilByButton[button] = now.addingTimeInterval(
            button == .voiceCommand ? voiceCommandSuppressionInterval : actionSuppressionInterval
        )

        let event = ButtonEvent(
            button: button,
            isDown: true,
            isRepeat: false,
            source: button == .voiceCommand ? .unifiedSystemVoiceCommand : .unifiedSystemAction,
            deviceName: extractDeviceIdentifier(from: line),
            rawDescription: line
        )

        DispatchQueue.main.async {
            let wasHandled = self.onButtonEvent?(event) ?? false
            if wasHandled {
                self.onLog?("Unified system action event was handled: \(button.displayName)")
            } else {
                self.onLog?("Unified system action event was observed but left as passthrough: \(button.displayName)")
            }
        }
    }

    private func decodeButton(from lowercasedLine: String) -> ButtonIdentifier? {
        if lowercasedLine.contains("received set voice command event") ||
            lowercasedLine.contains("voice command - activating siri") ||
            lowercasedLine.contains("sirincactionbvra1") {
            return .voiceCommand
        }

        if lowercasedLine.contains("volume up") {
            return .volumeUp
        }

        if lowercasedLine.contains("volume down") {
            return .volumeDown
        }

        if lowercasedLine.contains("toggle play/pause") ||
            lowercasedLine.contains("play/pause") ||
            lowercasedLine.contains("playpause") {
            return .playPause
        }

        if lowercasedLine.contains("next track") ||
            lowercasedLine.contains("nexttrack") {
            return .nextTrack
        }

        if lowercasedLine.contains("previous track") ||
            lowercasedLine.contains("previoustrack") {
            return .previousTrack
        }

        if lowercasedLine.contains(" remote command mute") ||
            lowercasedLine.contains(" remote command: mute") ||
            lowercasedLine.contains("mediaremote command mute") ||
            lowercasedLine.hasSuffix(" mute") {
            return .mute
        }

        return nil
    }

    private func extractDeviceIdentifier(from line: String) -> String? {
        guard let range = line.range(of: "device ", options: [.caseInsensitive]) else {
            return nil
        }

        let suffix = line[range.upperBound...]
        let identifier = suffix
            .prefix { $0.isHexDigit || $0 == ":" }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return identifier.isEmpty ? nil : String(identifier)
    }

    private var predicate: String {
        interestingProcesses
            .map { "process == \"\($0)\"" }
            .joined(separator: " OR ")
    }
}
