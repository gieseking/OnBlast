import Foundation

enum PrivateMediaRemoteCommand: UInt32, CaseIterable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
    case advanceShuffleMode = 6
    case advanceRepeatMode = 7
    case beginFastForward = 8
    case endFastForward = 9
    case beginRewind = 10
    case endRewind = 11
    case rewind15Seconds = 12
    case fastForward15Seconds = 13
    case rewind30Seconds = 14
    case fastForward30Seconds = 15
    case toggleRecord = 16
    case skipForward = 17
    case skipBackward = 18
    case changePlaybackRate = 19
    case rateTrack = 20
    case likeTrack = 21
    case dislikeTrack = 22
    case bookmarkTrack = 23
    case seekToPlaybackPosition = 24
    case changeRepeatMode = 25
    case changeShuffleMode = 26
    case enableLanguageOption = 27
    case disableLanguageOption = 28

    var displayName: String {
        switch self {
        case .play:
            return "Play"
        case .pause:
            return "Pause"
        case .togglePlayPause:
            return "Toggle Play/Pause"
        case .stop:
            return "Stop"
        case .nextTrack:
            return "Next Track"
        case .previousTrack:
            return "Previous Track"
        case .advanceShuffleMode:
            return "Advance Shuffle Mode"
        case .advanceRepeatMode:
            return "Advance Repeat Mode"
        case .beginFastForward:
            return "Begin Fast Forward"
        case .endFastForward:
            return "End Fast Forward"
        case .beginRewind:
            return "Begin Rewind"
        case .endRewind:
            return "End Rewind"
        case .rewind15Seconds:
            return "Rewind 15 Seconds"
        case .fastForward15Seconds:
            return "Fast Forward 15 Seconds"
        case .rewind30Seconds:
            return "Rewind 30 Seconds"
        case .fastForward30Seconds:
            return "Fast Forward 30 Seconds"
        case .toggleRecord:
            return "Toggle Record"
        case .skipForward:
            return "Skip Forward"
        case .skipBackward:
            return "Skip Backward"
        case .changePlaybackRate:
            return "Change Playback Rate"
        case .rateTrack:
            return "Rate Track"
        case .likeTrack:
            return "Like Track"
        case .dislikeTrack:
            return "Dislike Track"
        case .bookmarkTrack:
            return "Bookmark Track"
        case .seekToPlaybackPosition:
            return "Seek To Playback Position"
        case .changeRepeatMode:
            return "Change Repeat Mode"
        case .changeShuffleMode:
            return "Change Shuffle Mode"
        case .enableLanguageOption:
            return "Enable Language Option"
        case .disableLanguageOption:
            return "Disable Language Option"
        }
    }

    var mappedButton: ButtonIdentifier? {
        switch self {
        case .play, .pause, .togglePlayPause:
            return .playPause
        case .nextTrack:
            return .nextTrack
        case .previousTrack:
            return .previousTrack
        default:
            return nil
        }
    }
}

final class PrivateMediaRemoteBridge {
    var onLog: ((String) -> Void)?
    var onButtonEvent: ((ButtonEvent) -> Bool)?

    private typealias SendCommandFunction = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias GetLocalOriginFunction = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias SyncCommandHandlerBlock = @convention(block) (UInt32, CFDictionary?) -> CFArray?
    private typealias CommandCompletionBlock = @convention(block) (CFArray?) -> Void
    private typealias AsyncCommandHandlerBlock = @convention(block) (UInt32, CFDictionary?, CommandCompletionBlock) -> Void
    private typealias SupportedCommandsCompletionBlock = @convention(block) (UInt32) -> Void
    private typealias AddCommandHandlerFunction = @convention(c) (SyncCommandHandlerBlock) -> UnsafeMutableRawPointer?
    private typealias AddAsyncCommandHandlerFunction = @convention(c) (AsyncCommandHandlerBlock) -> UnsafeMutableRawPointer?
    private typealias RemoveCommandHandlerFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetSupportedCommandsFunction = @convention(c) (CFArray, UnsafeMutableRawPointer?, DispatchQueue?, SupportedCommandsCompletionBlock?) -> Void
    private typealias CommandInfoCreateFunction = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias CommandInfoSetCommandFunction = @convention(c) (CFTypeRef, UInt32) -> Void
    private typealias CommandInfoSetEnabledFunction = @convention(c) (CFTypeRef, Bool) -> Void
    private typealias RegisterNotificationsFunction = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterNotificationsFunction = @convention(c) () -> Void

    private var bundle: CFBundle?
    private var sendCommandFunction: SendCommandFunction?
    private var getLocalOriginFunction: GetLocalOriginFunction?
    private var addCommandHandlerFunction: AddCommandHandlerFunction?
    private var addAsyncCommandHandlerFunction: AddAsyncCommandHandlerFunction?
    private var removeCommandHandlerFunction: RemoveCommandHandlerFunction?
    private var setSupportedCommandsFunction: SetSupportedCommandsFunction?
    private var commandInfoCreateFunction: CommandInfoCreateFunction?
    private var commandInfoSetCommandFunction: CommandInfoSetCommandFunction?
    private var commandInfoSetEnabledFunction: CommandInfoSetEnabledFunction?
    private var registerNotificationsFunction: RegisterNotificationsFunction?
    private var unregisterNotificationsFunction: UnregisterNotificationsFunction?

    private var commandHandlerObserver: UnsafeMutableRawPointer?
    private var syncCommandHandlerBlock: SyncCommandHandlerBlock?
    private var commandHandlerBlock: AsyncCommandHandlerBlock?
    private var supportedCommandsCompletionBlock: SupportedCommandsCompletionBlock?

    private(set) var isLoaded = false

    func start(enabled: Bool, configuration: AppConfiguration) {
        stop()

        guard enabled else {
            return
        }

        guard let bundleURL = URL(string: "file:///System/Library/PrivateFrameworks/MediaRemote.framework") else {
            onLog?("MediaRemote bundle URL was invalid")
            return
        }

        guard let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL as CFURL) else {
            onLog?("Failed to create MediaRemote bundle reference")
            return
        }

        self.bundle = bundle
        CFBundleLoadExecutable(bundle)

        sendCommandFunction = resolveFunction(named: "MRMediaRemoteSendCommand", as: SendCommandFunction.self)
        getLocalOriginFunction = resolveFunction(named: "MRMediaRemoteGetLocalOrigin", as: GetLocalOriginFunction.self)
        addCommandHandlerFunction = resolveFunction(named: "MRMediaRemoteAddCommandHandlerBlock", as: AddCommandHandlerFunction.self)
        addAsyncCommandHandlerFunction = resolveFunction(named: "MRMediaRemoteAddAsyncCommandHandlerBlock", as: AddAsyncCommandHandlerFunction.self)
        removeCommandHandlerFunction = resolveFunction(named: "MRMediaRemoteRemoveCommandHandlerBlock", as: RemoveCommandHandlerFunction.self)
        setSupportedCommandsFunction = resolveFunction(named: "MRMediaRemoteSetSupportedCommands", as: SetSupportedCommandsFunction.self)
        commandInfoCreateFunction = resolveFunction(named: "MRMediaRemoteCommandInfoCreate", as: CommandInfoCreateFunction.self)
        commandInfoSetCommandFunction = resolveFunction(named: "MRMediaRemoteCommandInfoSetCommand", as: CommandInfoSetCommandFunction.self)
        commandInfoSetEnabledFunction = resolveFunction(named: "MRMediaRemoteCommandInfoSetEnabled", as: CommandInfoSetEnabledFunction.self)
        registerNotificationsFunction = resolveFunction(named: "MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterNotificationsFunction.self)
        unregisterNotificationsFunction = resolveFunction(named: "MRMediaRemoteUnregisterForNowPlayingNotifications", as: UnregisterNotificationsFunction.self)

        isLoaded = sendCommandFunction != nil || addAsyncCommandHandlerFunction != nil || addCommandHandlerFunction != nil
        logResolvedSymbols()

        registerNotificationsFunction?(.main)

        let supportedCommands = supportedCommands(for: configuration)
        if supportedCommands.isEmpty {
            onLog?("MediaRemote bridge loaded, but no non-passthrough MediaRemote mappings are enabled")
        } else {
            registerCommandHandler(for: supportedCommands)
        }

        if commandHandlerObserver != nil {
            onLog?("MediaRemote bridge loaded with command handler")
        } else if isLoaded && supportedCommands.isEmpty {
            onLog?("MediaRemote bridge is idle until a button is mapped to a non-passthrough MediaRemote action")
        } else if isLoaded {
            onLog?("MediaRemote bridge loaded, but command handler registration failed")
        } else {
            onLog?("MediaRemote bridge did not expose expected symbols on this macOS build")
        }
    }

    func stop() {
        if let removeCommandHandlerFunction, commandHandlerObserver != nil {
            removeCommandHandlerFunction(commandHandlerObserver)
        }

        if isLoaded {
            unregisterNotificationsFunction?()
        }

        commandHandlerObserver = nil
        syncCommandHandlerBlock = nil
        commandHandlerBlock = nil
        supportedCommandsCompletionBlock = nil
        bundle = nil
        sendCommandFunction = nil
        getLocalOriginFunction = nil
        addCommandHandlerFunction = nil
        addAsyncCommandHandlerFunction = nil
        removeCommandHandlerFunction = nil
        setSupportedCommandsFunction = nil
        commandInfoCreateFunction = nil
        commandInfoSetCommandFunction = nil
        commandInfoSetEnabledFunction = nil
        registerNotificationsFunction = nil
        unregisterNotificationsFunction = nil
        isLoaded = false
    }

    @discardableResult
    func send(command: PrivateMediaRemoteCommand) -> Bool {
        guard let sendCommandFunction else {
            onLog?("MediaRemote sendCommand symbol is unavailable")
            return false
        }

        return sendCommandFunction(command.rawValue, nil)
    }

    private func registerCommandHandler(for supportedCommands: [PrivateMediaRemoteCommand]) {
        guard
            let getLocalOriginFunction,
            let setSupportedCommandsFunction,
            let commandInfoCreateFunction,
            let commandInfoSetCommandFunction,
            let commandInfoSetEnabledFunction
        else {
            onLog?("MediaRemote registration prerequisites are missing")
            return
        }

        let commandInfoObjects = supportedCommands.compactMap { command -> AnyObject? in
            guard let commandInfo = commandInfoCreateFunction(kCFAllocatorDefault)?.takeRetainedValue() else {
                return nil
            }

            commandInfoSetCommandFunction(commandInfo, command.rawValue)
            commandInfoSetEnabledFunction(commandInfo, true)
            return commandInfo
        }

        guard !commandInfoObjects.isEmpty else {
            onLog?("MediaRemote could not build supported command info objects")
            return
        }

        let supportedArray = commandInfoObjects as CFArray
        supportedCommandsCompletionBlock = { [weak self] errorCode in
            if errorCode == 0 {
                self?.onLog?("MediaRemote accepted supported command registration")
                return
            }

            self?.onLog?("MediaRemote rejected supported command registration with error \(errorCode)")
        }
        setSupportedCommandsFunction(
            supportedArray,
            getLocalOriginFunction(),
            DispatchQueue.main,
            supportedCommandsCompletionBlock
        )

        let handledResponse = [NSNumber(value: 0)] as CFArray
        let unhandledResponse = [] as NSArray as CFArray
        let asyncBlock: AsyncCommandHandlerBlock = { [weak self] rawCommand, options, completion in
            guard let self else {
                completion(unhandledResponse)
                return
            }

            guard let command = PrivateMediaRemoteCommand(rawValue: rawCommand) else {
                self.onLog?("Observed unknown MediaRemote command rawValue=\(rawCommand)")
                completion(unhandledResponse)
                return
            }

            let wasHandled = self.handleIncoming(command: command, options: options)
            completion(wasHandled ? handledResponse : unhandledResponse)
        }
        commandHandlerBlock = asyncBlock

        let syncBlock: SyncCommandHandlerBlock = { [weak self] rawCommand, options in
            guard let self else {
                return unhandledResponse
            }

            guard let command = PrivateMediaRemoteCommand(rawValue: rawCommand) else {
                self.onLog?("Observed unknown MediaRemote command rawValue=\(rawCommand)")
                return unhandledResponse
            }

            let wasHandled = self.handleIncoming(command: command, options: options)
            return wasHandled ? handledResponse : unhandledResponse
        }
        syncCommandHandlerBlock = syncBlock

        if let addAsyncCommandHandlerFunction {
            commandHandlerObserver = addAsyncCommandHandlerFunction(asyncBlock)
            if commandHandlerObserver != nil {
                onLog?("MediaRemote async command handler registered")
            } else {
                onLog?("MediaRemote async command handler registration returned nil")
            }
        } else {
            onLog?("MediaRemote async command handler symbol is unavailable")
        }

        if commandHandlerObserver == nil, let addCommandHandlerFunction {
            commandHandlerObserver = addCommandHandlerFunction(syncBlock)
            if commandHandlerObserver != nil {
                onLog?("MediaRemote sync command handler registered")
            } else {
                onLog?("MediaRemote sync command handler registration returned nil")
            }
        } else if commandHandlerObserver == nil {
            onLog?("MediaRemote sync command handler symbol is unavailable")
        }

        let supportedSummary = supportedCommands.map(\.displayName).joined(separator: ", ")
        onLog?("Registered MediaRemote commands: \(supportedSummary)")
    }

    private func handleIncoming(command: PrivateMediaRemoteCommand, options: CFDictionary?) -> Bool {
        guard let button = command.mappedButton else {
            onLog?("Observed unsupported MediaRemote command: \(command.displayName)")
            return false
        }

        let rawDescription: String
        if let options, let description = CFCopyDescription(options) {
            rawDescription = "\(command.displayName) options=\(description)"
        } else {
            rawDescription = command.displayName
        }

        let event = ButtonEvent(
            button: button,
            isDown: true,
            isRepeat: false,
            source: .privateMediaRemote,
            deviceName: "MediaRemote",
            rawDescription: rawDescription
        )

        let shouldConsume = onButtonEvent?(event) ?? false
        if shouldConsume {
            onLog?("Consumed MediaRemote command: \(command.displayName)")
        } else {
            onLog?("Observed MediaRemote command without interception: \(command.displayName)")
        }

        return shouldConsume
    }

    private func supportedCommands(for configuration: AppConfiguration) -> [PrivateMediaRemoteCommand] {
        // When the bridge is enabled, register every known command so we can
        // diagnose what the headset is actually emitting even before we know how
        // to map it cleanly.
        return PrivateMediaRemoteCommand.allCases
    }

    private func resolveFunction<T>(named name: String, as type: T.Type) -> T? {
        guard let bundle else {
            return nil
        }

        guard let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
            return nil
        }

        return unsafeBitCast(pointer, to: type)
    }

    private func logResolvedSymbols() {
        let statuses = [
            "MRMediaRemoteSendCommand": sendCommandFunction != nil,
            "MRMediaRemoteGetLocalOrigin": getLocalOriginFunction != nil,
            "MRMediaRemoteAddAsyncCommandHandlerBlock": addAsyncCommandHandlerFunction != nil,
            "MRMediaRemoteAddCommandHandlerBlock": addCommandHandlerFunction != nil,
            "MRMediaRemoteRemoveCommandHandlerBlock": removeCommandHandlerFunction != nil,
            "MRMediaRemoteSetSupportedCommands": setSupportedCommandsFunction != nil,
            "MRMediaRemoteCommandInfoCreate": commandInfoCreateFunction != nil,
            "MRMediaRemoteCommandInfoSetCommand": commandInfoSetCommandFunction != nil,
            "MRMediaRemoteCommandInfoSetEnabled": commandInfoSetEnabledFunction != nil
        ]

        let summary = statuses
            .map { "\($0.key)=\($0.value ? "yes" : "no")" }
            .joined(separator: ", ")
        onLog?("MediaRemote symbols: \(summary)")
    }
}
