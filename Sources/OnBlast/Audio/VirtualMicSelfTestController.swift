import AVFoundation
import Foundation

final class VirtualMicSelfTestController: NSObject, @unchecked Sendable {
    var onLog: ((String) -> Void)?
    var onStatusChange: ((String, Bool) -> Void)?

    private let helperTimeoutMargin: TimeInterval = 4.0

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var timeoutWorkItem: DispatchWorkItem?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var isBusy = false

    func runTest(virtualDeviceUID: String, virtualDeviceName: String) {
        guard !isBusy else {
            publishStatus("Virtual mic self-test is already running", isBusy: true)
            return
        }

        guard let helperURL = helperExecutableURL() else {
            publishFailure("Virtual mic self-test helper is missing from the app bundle")
            return
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OnBlast-VirtualMicSelfTest-\(UUID().uuidString).caf")

        cleanup()
        isBusy = true
        recordingURL = outputURL
        publishStatus("Say something now. Recording from \(virtualDeviceName)...", isBusy: true)

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--device-uid", virtualDeviceUID,
            "--device-name", virtualDeviceName,
            "--duration", "3.5",
            "--output", outputURL.path
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.consumeLogData(handle.availableData)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            self?.consumeLogData(handle.availableData)
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleHelperTermination(process)
            }
        }

        self.process = process
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.handleTimeout()
            }
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5 + helperTimeoutMargin, execute: timeoutWorkItem)

        do {
            try process.run()
            emitLog("Virtual mic self-test helper launched")
        } catch {
            publishFailure("Virtual mic self-test could not start the helper: \(error.localizedDescription)")
        }
    }

    private func handleHelperTermination(_ process: Process) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        self.process = nil

        guard process.terminationReason == .exit else {
            publishFailure("Virtual mic self-test helper terminated unexpectedly")
            return
        }

        switch process.terminationStatus {
        case 0:
            guard let recordingURL else {
                publishFailure("Virtual mic self-test completed without an output recording")
                return
            }
            playRecording(at: recordingURL)
        case 2:
            publishFailure("Virtual mic self-test captured only silence")
        default:
            publishFailure("Virtual mic self-test failed")
        }
    }

    private func handleTimeout() {
        guard let process else {
            return
        }

        emitLog("Virtual mic self-test helper timed out; terminating it to keep the app responsive")
        if process.isRunning {
            process.terminate()
        }
        publishFailure("Virtual mic self-test timed out")
    }

    private func playRecording(at url: URL) {
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()
            self.audioPlayer = audioPlayer
            publishStatus("Playing back what the virtual mic recorded...", isBusy: true)
            emitLog("Virtual mic self-test recorded audio successfully; starting playback")
            audioPlayer.play()
        } catch {
            publishFailure("Virtual mic self-test could not play back the recording: \(error.localizedDescription)")
        }
    }

    private func helperExecutableURL() -> URL? {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("VirtualMicSelfTestHelper"),
           FileManager.default.isExecutableFile(atPath: resourceURL.path) {
            return resourceURL
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for candidate in [
            cwd.appendingPathComponent(".build/debug/VirtualMicSelfTestHelper"),
            cwd.appendingPathComponent(".build/release/VirtualMicSelfTestHelper")
        ] where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        return nil
    }

    private func consumeLogData(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return
        }

        DispatchQueue.main.async {
            lines.forEach { self.onLog?($0) }
        }
    }

    private func publishStatus(_ message: String, isBusy: Bool) {
        let onStatusChange = self.onStatusChange
        DispatchQueue.main.async {
            onStatusChange?(message, isBusy)
        }
    }

    private func emitLog(_ message: String) {
        let onLog = self.onLog
        DispatchQueue.main.async {
            onLog?(message)
        }
    }

    private func publishFailure(_ reason: String) {
        emitLog(reason)
        isBusy = false
        publishStatus(reason, isBusy: false)
        cleanup()
    }

    private func completeTest() {
        isBusy = false
        emitLog("Virtual mic self-test completed")
        publishStatus("Virtual mic self-test completed", isBusy: false)
        cleanup()
    }

    private func cleanup() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil

        audioPlayer?.stop()
        audioPlayer = nil

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }
}

extension VirtualMicSelfTestController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        _ = player
        DispatchQueue.main.async {
            if flag {
                self.completeTest()
            } else {
                self.publishFailure("Virtual mic self-test playback did not finish successfully")
            }
        }
    }
}
