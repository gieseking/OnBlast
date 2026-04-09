import Foundation

enum ButtonIdentifier: String, CaseIterable, Codable, Identifiable {
    case voiceCommand
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute
    case systemMicMute
    case callMuteToggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voiceCommand:
            return "Voice Command / Center Button"
        case .playPause:
            return "Play / Pause"
        case .nextTrack:
            return "Next Track"
        case .previousTrack:
            return "Previous Track"
        case .volumeUp:
            return "Volume Up"
        case .volumeDown:
            return "Volume Down"
        case .mute:
            return "Mute"
        case .systemMicMute:
            return "System Microphone Mute"
        case .callMuteToggle:
            return "Call Mute Toggle"
        }
    }
}

enum ButtonAction: String, CaseIterable, Codable, Identifiable {
    case passthrough
    case none
    case toggleMicMute
    case mediaPlayPause
    case mediaNextTrack
    case mediaPreviousTrack
    case mediaMute
    case mediaVolumeUp
    case mediaVolumeDown
    case functionF13
    case functionF14
    case functionF15
    case functionF16
    case functionF17
    case functionF18
    case functionF19
    case functionF20

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .passthrough:
            return "Passthrough"
        case .none:
            return "Consume and Do Nothing"
        case .toggleMicMute:
            return "Toggle Mic Mute"
        case .mediaPlayPause:
            return "Send Play / Pause"
        case .mediaNextTrack:
            return "Send Next Track"
        case .mediaPreviousTrack:
            return "Send Previous Track"
        case .mediaMute:
            return "Send Mute"
        case .mediaVolumeUp:
            return "Send Volume Up"
        case .mediaVolumeDown:
            return "Send Volume Down"
        case .functionF13:
            return "Send F13"
        case .functionF14:
            return "Send F14"
        case .functionF15:
            return "Send F15"
        case .functionF16:
            return "Send F16"
        case .functionF17:
            return "Send F17"
        case .functionF18:
            return "Send F18"
        case .functionF19:
            return "Send F19"
        case .functionF20:
            return "Send F20"
        }
    }
}

enum MicState: String {
    case muted
    case live
    case unavailable
    case unknown

    var displayName: String {
        switch self {
        case .muted:
            return "Muted"
        case .live:
            return "Live"
        case .unavailable:
            return "Unavailable"
        case .unknown:
            return "Unknown"
        }
    }
}

enum MicMuteBackend: String, CaseIterable, Codable, Identifiable {
    case deviceMute
    case virtualMicProxy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deviceMute:
            return "Device Mute"
        case .virtualMicProxy:
            return "Virtual Mic Proxy"
        }
    }
}

enum InputSourceRoute: String {
    case systemDefined = "SystemDefined"
    case hid = "HID"
    case hidExclusive = "HID Exclusive"
    case privateMediaRemote = "MediaRemote"
    case bluetoothHandsFree = "Bluetooth HFP"
    case unifiedSystemVoiceCommand = "System Voice Log"
    case unifiedSystemAction = "System Action Log"
    case siriActivation = "Siri Fallback"
}

struct ButtonEvent: Identifiable {
    let id = UUID()
    let button: ButtonIdentifier
    let isDown: Bool
    let isRepeat: Bool
    let source: InputSourceRoute
    let deviceName: String?
    let rawDescription: String
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let text: String
}

struct AudioDeviceOption: Identifiable, Hashable {
    let uid: String
    let name: String
    let manufacturer: String
    let transportDescription: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    let nominalSampleRate: Double
    let isVirtual: Bool

    var id: String { uid }

    var displayName: String {
        let channelDescription = "in \(inputChannelCount) / out \(outputChannelCount)"
        return "\(name) • \(manufacturer) • \(transportDescription) • \(channelDescription)"
    }
}

struct HIDDeviceSummary: Identifiable, Hashable {
    let id: String
    let productName: String
    let manufacturer: String
    let transport: String
    let vendorID: Int
    let productID: Int
    let isExclusive: Bool
}

struct AppConfiguration: Codable {
    var startAtLogin: Bool = false
    var enableSystemDefinedEventTap: Bool = true
    var enableHIDMonitor: Bool = true
    var enableExclusiveBoseCapture: Bool = true
    var enablePrivateMediaRemoteBridge: Bool = false
    var enableBluetoothHandsFreeMonitor: Bool = true
    var enableSiriActivationFallback: Bool = true
    var enableSpokenAnnouncements: Bool = true
    var enableMutedSpeechReminder: Bool = true
    var micMuteBackend: MicMuteBackend = .deviceMute
    var virtualMicInputDeviceUID: String = ""
    var virtualMicOutputDeviceUID: String = ""
    var spokenAnnouncementVolume: Double = 1.0
    var spokenMutedAnnouncement: String = "Microphone is muted"
    var spokenLiveAnnouncement: String = "Microphone is live"
    var muteSoundFilePath: String = ""
    var liveSoundFilePath: String = ""
    var consumeInterceptedEvents: Bool = true
    var boseNameFilter: String = "Bose"
    var menuBarTitle: String = "MBI"
    private var mappings: [String: ButtonAction] = AppConfiguration.defaultMappings

    static let storageKey = "com.gieseking.MediaButtonInterceptor.configuration"

    static let defaultMappings: [String: ButtonAction] = [
        ButtonIdentifier.voiceCommand.rawValue: .toggleMicMute,
        ButtonIdentifier.playPause.rawValue: .passthrough,
        ButtonIdentifier.nextTrack.rawValue: .passthrough,
        ButtonIdentifier.previousTrack.rawValue: .passthrough,
        ButtonIdentifier.volumeUp.rawValue: .passthrough,
        ButtonIdentifier.volumeDown.rawValue: .passthrough,
        ButtonIdentifier.mute.rawValue: .mediaMute,
        ButtonIdentifier.systemMicMute.rawValue: .toggleMicMute,
        ButtonIdentifier.callMuteToggle.rawValue: .toggleMicMute
    ]

    func action(for button: ButtonIdentifier) -> ButtonAction {
        mappings[button.rawValue] ?? AppConfiguration.defaultMappings[button.rawValue] ?? .passthrough
    }

    mutating func setAction(_ action: ButtonAction, for button: ButtonIdentifier) {
        mappings[button.rawValue] = action
    }

    init() {}

    static func load() -> AppConfiguration {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let configuration = try? JSONDecoder().decode(AppConfiguration.self, from: data)
        else {
            return AppConfiguration()
        }

        return configuration
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: AppConfiguration.storageKey)
    }

    private enum CodingKeys: String, CodingKey {
        case startAtLogin
        case enableSystemDefinedEventTap
        case enableHIDMonitor
        case enableExclusiveBoseCapture
        case enablePrivateMediaRemoteBridge
        case enableBluetoothHandsFreeMonitor
        case enableSiriActivationFallback
        case enableSpokenAnnouncements
        case enableMutedSpeechReminder
        case micMuteBackend
        case virtualMicInputDeviceUID
        case virtualMicOutputDeviceUID
        case spokenAnnouncementVolume
        case spokenMutedAnnouncement
        case spokenLiveAnnouncement
        case muteSoundFilePath
        case liveSoundFilePath
        case consumeInterceptedEvents
        case boseNameFilter
        case menuBarTitle
        case mappings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        enableSystemDefinedEventTap = try container.decodeIfPresent(Bool.self, forKey: .enableSystemDefinedEventTap) ?? true
        enableHIDMonitor = try container.decodeIfPresent(Bool.self, forKey: .enableHIDMonitor) ?? true
        enableExclusiveBoseCapture = try container.decodeIfPresent(Bool.self, forKey: .enableExclusiveBoseCapture) ?? true
        enablePrivateMediaRemoteBridge = try container.decodeIfPresent(Bool.self, forKey: .enablePrivateMediaRemoteBridge) ?? false
        enableBluetoothHandsFreeMonitor = try container.decodeIfPresent(Bool.self, forKey: .enableBluetoothHandsFreeMonitor) ?? true
        enableSiriActivationFallback = try container.decodeIfPresent(Bool.self, forKey: .enableSiriActivationFallback) ?? true
        enableSpokenAnnouncements = try container.decodeIfPresent(Bool.self, forKey: .enableSpokenAnnouncements) ?? true
        enableMutedSpeechReminder = try container.decodeIfPresent(Bool.self, forKey: .enableMutedSpeechReminder) ?? true
        micMuteBackend = try container.decodeIfPresent(MicMuteBackend.self, forKey: .micMuteBackend) ?? .deviceMute
        virtualMicInputDeviceUID = try container.decodeIfPresent(String.self, forKey: .virtualMicInputDeviceUID) ?? ""
        virtualMicOutputDeviceUID = try container.decodeIfPresent(String.self, forKey: .virtualMicOutputDeviceUID) ?? ""
        spokenAnnouncementVolume = min(max(try container.decodeIfPresent(Double.self, forKey: .spokenAnnouncementVolume) ?? 1.0, 0.0), 1.0)
        spokenMutedAnnouncement = try container.decodeIfPresent(String.self, forKey: .spokenMutedAnnouncement) ?? "Microphone is muted"
        spokenLiveAnnouncement = try container.decodeIfPresent(String.self, forKey: .spokenLiveAnnouncement) ?? "Microphone is live"
        muteSoundFilePath = try container.decodeIfPresent(String.self, forKey: .muteSoundFilePath) ?? ""
        liveSoundFilePath = try container.decodeIfPresent(String.self, forKey: .liveSoundFilePath) ?? ""
        consumeInterceptedEvents = try container.decodeIfPresent(Bool.self, forKey: .consumeInterceptedEvents) ?? true
        boseNameFilter = try container.decodeIfPresent(String.self, forKey: .boseNameFilter) ?? "Bose"
        menuBarTitle = try container.decodeIfPresent(String.self, forKey: .menuBarTitle) ?? "MBI"
        mappings = try container.decodeIfPresent([String: ButtonAction].self, forKey: .mappings) ?? AppConfiguration.defaultMappings
    }
}
