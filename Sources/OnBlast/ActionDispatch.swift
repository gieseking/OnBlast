import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation

final class EventInjectionGuard: @unchecked Sendable {
    static let shared = EventInjectionGuard()

    private let lock = NSLock()
    private var ignoreUntil = Date.distantPast

    private init() {}

    func beginSyntheticBurst(for duration: TimeInterval = 0.35) {
        lock.lock()
        ignoreUntil = Date().addingTimeInterval(duration)
        lock.unlock()
    }

    var shouldIgnoreSyntheticEvents: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date() < ignoreUntil
    }
}

final class ActionDispatcher {
    var onLog: ((String) -> Void)?
    private let speechSynthesizer = NSSpeechSynthesizer()
    private var spokenAnnouncementsEnabled = true
    private var spokenMutedAnnouncement = "Microphone is muted"
    private var spokenLiveAnnouncement = "Microphone is live"
    private var muteSoundURL: URL?
    private var liveSoundURL: URL?
    private var soundPlayer: AVAudioPlayer?

    init() {
        speechSynthesizer.rate = 180
        speechSynthesizer.volume = 1.0
    }

    func configure(
        spokenAnnouncementsEnabled: Bool,
        spokenAnnouncementVolume: Double,
        spokenMutedAnnouncement: String,
        spokenLiveAnnouncement: String,
        muteSoundFilePath: String,
        liveSoundFilePath: String
    ) {
        self.spokenAnnouncementsEnabled = spokenAnnouncementsEnabled
        speechSynthesizer.volume = Float(min(max(spokenAnnouncementVolume, 0.0), 1.0))
        self.spokenMutedAnnouncement = spokenMutedAnnouncement
        self.spokenLiveAnnouncement = spokenLiveAnnouncement
        muteSoundURL = Self.fileURL(for: muteSoundFilePath)
        liveSoundURL = Self.fileURL(for: liveSoundFilePath)
    }

    func perform(_ action: ButtonAction, micController: MicMuteControlling, privateBridge: PrivateMediaRemoteBridge?) {
        switch action {
        case .passthrough:
            return
        case .none:
            onLog?("Consumed event without forwarding it")
        case .toggleMicMute:
            do {
                let muted = try micController.toggleMute()
                let logAnnouncement = muted ? "Microphone muted" : "Microphone live"
                onLog?(logAnnouncement)
                announceMicState(isMuted: muted)
            } catch {
                onLog?("Failed to toggle microphone mute: \(error.localizedDescription)")
            }
        case .mediaPlayPause:
            if privateBridge?.isLoaded == true, privateBridge?.send(command: .togglePlayPause) == true {
                onLog?("Sent play/pause through MediaRemote")
            } else {
                postMediaKey(nxKeyType: 16)
            }
        case .mediaNextTrack:
            if privateBridge?.isLoaded == true, privateBridge?.send(command: .nextTrack) == true {
                onLog?("Sent next track through MediaRemote")
            } else {
                postMediaKey(nxKeyType: 17)
            }
        case .mediaPreviousTrack:
            if privateBridge?.isLoaded == true, privateBridge?.send(command: .previousTrack) == true {
                onLog?("Sent previous track through MediaRemote")
            } else {
                postMediaKey(nxKeyType: 18)
            }
        case .mediaMute:
            postMediaKey(nxKeyType: 7)
        case .mediaVolumeUp:
            postMediaKey(nxKeyType: 0)
        case .mediaVolumeDown:
            postMediaKey(nxKeyType: 1)
        case .functionF13:
            postFunctionKey(keyCode: CGKeyCode(kVK_F13))
        case .functionF14:
            postFunctionKey(keyCode: CGKeyCode(kVK_F14))
        case .functionF15:
            postFunctionKey(keyCode: CGKeyCode(kVK_F15))
        case .functionF16:
            postFunctionKey(keyCode: CGKeyCode(kVK_F16))
        case .functionF17:
            postFunctionKey(keyCode: CGKeyCode(kVK_F17))
        case .functionF18:
            postFunctionKey(keyCode: CGKeyCode(kVK_F18))
        case .functionF19:
            postFunctionKey(keyCode: CGKeyCode(kVK_F19))
        case .functionF20:
            postFunctionKey(keyCode: CGKeyCode(kVK_F20))
        }
    }

    private func postFunctionKey(keyCode: CGKeyCode) {
        EventInjectionGuard.shared.beginSyntheticBurst()
        let source = CGEventSource(stateID: .hidSystemState)

        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
                continue
            }

            event.post(tap: .cghidEventTap)
        }

        onLog?("Posted keyboard function key")
    }

    private func postMediaKey(nxKeyType: Int32) {
        EventInjectionGuard.shared.beginSyntheticBurst()

        let states: [(Bool, UInt)] = [
            (true, 0xA00),
            (false, 0xB00)
        ]

        for (isDown, flags) in states {
            let stateBits: Int32 = isDown ? 0xA : 0xB
            let data1 = Int((nxKeyType << 16) | (stateBits << 8))

            guard
                let event = NSEvent.otherEvent(
                    with: .systemDefined,
                    location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    subtype: 8,
                    data1: data1,
                    data2: -1
                ),
                let cgEvent = event.cgEvent
            else {
                continue
            }

            cgEvent.post(tap: .cghidEventTap)
        }

        onLog?("Posted synthetic media key \(nxKeyType)")
    }

    func playMutedReminder() {
        onLog?("Detected speech while muted; replaying muted reminder")
        announceMicState(isMuted: true)
    }

    private func announceMicState(isMuted: Bool) {
        let spokenAnnouncement = isMuted ? spokenMutedAnnouncement : spokenLiveAnnouncement
        speak(spokenAnnouncement)
        playSound(from: isMuted ? muteSoundURL : liveSoundURL)
    }

    private func speak(_ phrase: String) {
        guard spokenAnnouncementsEnabled else {
            return
        }

        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else {
            return
        }

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediateBoundary)
        }

        guard speechSynthesizer.startSpeaking(trimmedPhrase) else {
            onLog?("Failed to start spoken announcement")
            return
        }

        onLog?("Played spoken announcement")
    }

    private func playSound(from url: URL?) {
        guard let url else {
            return
        }

        do {
            soundPlayer?.stop()
            soundPlayer = try AVAudioPlayer(contentsOf: url)
            soundPlayer?.volume = 1.0
            soundPlayer?.prepareToPlay()

            if soundPlayer?.play() == true {
                onLog?("Played custom announcement sound")
            } else {
                onLog?("Failed to play custom announcement sound")
            }
        } catch {
            onLog?("Failed to load custom announcement sound: \(error.localizedDescription)")
        }
    }

    private static func fileURL(for path: String) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: trimmedPath)
    }
}
