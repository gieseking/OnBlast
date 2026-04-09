import Foundation
import ObjectiveC.runtime

final class PrivateBluetoothManagerMonitor: @unchecked Sendable {
    var onLog: ((String) -> Void)?

    private static let bundlePath = "/System/Library/PrivateFrameworks/BluetoothManager.framework"

    nonisolated(unsafe) private static var activeMonitor: PrivateBluetoothManagerMonitor?
    nonisolated(unsafe) private static var didInstallSwizzles = false
    nonisolated(unsafe) private static var retainedBlocks: [AnyObject] = []

    nonisolated(unsafe) private static var originalManagerPostNotification: IMP?
    nonisolated(unsafe) private static var originalManagerPostNotificationNameObject: IMP?
    nonisolated(unsafe) private static var originalManagerPostNotificationNameObjectError: IMP?
    nonisolated(unsafe) private static var originalManagerStartVoiceCommand: IMP?
    nonisolated(unsafe) private static var originalManagerEndVoiceCommand: IMP?
    nonisolated(unsafe) private static var originalDeviceStartVoiceCommand: IMP?
    nonisolated(unsafe) private static var originalDeviceEndVoiceCommand: IMP?

    private var loadedBundle: Bundle?
    private var manager: NSObject?

    func start(configuration: AppConfiguration) {
        stop()

        guard shouldEnable(for: configuration) else {
            return
        }

        guard let bundle = Bundle(path: Self.bundlePath) else {
            log("BluetoothManager private framework bundle is unavailable")
            return
        }

        _ = bundle.load()
        loadedBundle = bundle

        guard let managerClass = NSClassFromString("BluetoothManager") as? NSObject.Type else {
            log("BluetoothManager class is unavailable on this macOS build")
            return
        }

        Self.activeMonitor = self
        Self.installSwizzlesIfNeeded()

        let sharedSelector = NSSelectorFromString("sharedInstance")
        guard
            managerClass.responds(to: sharedSelector),
            let manager = managerClass.perform(sharedSelector)?.takeUnretainedValue() as? NSObject
        else {
            log("BluetoothManager sharedInstance is unavailable")
            return
        }

        self.manager = manager
        if manager.responds(to: NSSelectorFromString("_attach")) {
            _ = manager.perform(NSSelectorFromString("_attach"))
        }

        log("BluetoothManager private monitor attached")
    }

    func stop() {
        if Self.activeMonitor === self {
            Self.activeMonitor = nil
        }

        manager = nil
        loadedBundle = nil
    }

    private func shouldEnable(for configuration: AppConfiguration) -> Bool {
        configuration.enableBluetoothHandsFreeMonitor ||
        configuration.enableSiriActivationFallback
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.onLog?(message)
        }
    }

    private func handleManagerNotification(name: String?, object: AnyObject?, error: AnyObject?) {
        let nameDescription = name ?? "(unnamed)"
        let objectDescription = object.map { String(describing: $0) } ?? "nil"
        let errorDescription = error.map { String(describing: $0) } ?? "nil"
        log("BluetoothManager notification: name=\(nameDescription) object=\(objectDescription) error=\(errorDescription)")
    }

    private func handleManagerVoiceCommand(selectorName: String, argument: AnyObject?) {
        let argumentDescription = argument.map { String(describing: $0) } ?? "nil"
        log("BluetoothManager voice-command method called: \(selectorName) arg=\(argumentDescription)")
    }

    private func handleDeviceVoiceCommand(selectorName: String, device: AnyObject) {
        log("BluetoothDevice voice-command method called: \(selectorName) device=\(String(describing: device))")
    }

    private static func installSwizzlesIfNeeded() {
        guard !didInstallSwizzles else {
            return
        }

        didInstallSwizzles = true

        if let managerClass = NSClassFromString("BluetoothManager") {
            let managerPostNotificationBlock: @convention(block) (AnyObject, Notification) -> Void = { object, notification in
                activeMonitor?.handleManagerNotification(
                    name: notification.name.rawValue,
                    object: notification.object as AnyObject?,
                    error: nil
                )

                if let originalManagerPostNotification {
                    typealias Function = @convention(c) (AnyObject, Selector, Notification) -> Void
                    let function = unsafeBitCast(originalManagerPostNotification, to: Function.self)
                    function(object, NSSelectorFromString("postNotification:"), notification)
                }
            }
            originalManagerPostNotification = swizzleVoidMethod(
                on: managerClass,
                selectorName: "postNotification:",
                replacement: managerPostNotificationBlock
            )

            let managerPostNotificationNameObjectBlock: @convention(block) (AnyObject, NSString?, AnyObject?) -> Void = { object, name, payload in
                activeMonitor?.handleManagerNotification(name: name as String?, object: payload, error: nil)

                if let originalManagerPostNotificationNameObject {
                    typealias Function = @convention(c) (AnyObject, Selector, NSString?, AnyObject?) -> Void
                    let function = unsafeBitCast(originalManagerPostNotificationNameObject, to: Function.self)
                    function(object, NSSelectorFromString("postNotificationName:object:"), name, payload)
                }
            }
            originalManagerPostNotificationNameObject = swizzleVoidMethod(
                on: managerClass,
                selectorName: "postNotificationName:object:",
                replacement: managerPostNotificationNameObjectBlock
            )

            let managerPostNotificationNameObjectErrorBlock: @convention(block) (AnyObject, NSString?, AnyObject?, AnyObject?) -> Void = { object, name, payload, error in
                activeMonitor?.handleManagerNotification(name: name as String?, object: payload, error: error)

                if let originalManagerPostNotificationNameObjectError {
                    typealias Function = @convention(c) (AnyObject, Selector, NSString?, AnyObject?, AnyObject?) -> Void
                    let function = unsafeBitCast(originalManagerPostNotificationNameObjectError, to: Function.self)
                    function(object, NSSelectorFromString("postNotificationName:object:error:"), name, payload, error)
                }
            }
            originalManagerPostNotificationNameObjectError = swizzleVoidMethod(
                on: managerClass,
                selectorName: "postNotificationName:object:error:",
                replacement: managerPostNotificationNameObjectErrorBlock
            )

            let managerStartVoiceCommandBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { object, argument in
                activeMonitor?.handleManagerVoiceCommand(selectorName: "startVoiceCommand:", argument: argument)

                if let originalManagerStartVoiceCommand {
                    typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                    let function = unsafeBitCast(originalManagerStartVoiceCommand, to: Function.self)
                    function(object, NSSelectorFromString("startVoiceCommand:"), argument)
                }
            }
            originalManagerStartVoiceCommand = swizzleVoidMethod(
                on: managerClass,
                selectorName: "startVoiceCommand:",
                replacement: managerStartVoiceCommandBlock
            )

            let managerEndVoiceCommandBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { object, argument in
                activeMonitor?.handleManagerVoiceCommand(selectorName: "endVoiceCommand:", argument: argument)

                if let originalManagerEndVoiceCommand {
                    typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                    let function = unsafeBitCast(originalManagerEndVoiceCommand, to: Function.self)
                    function(object, NSSelectorFromString("endVoiceCommand:"), argument)
                }
            }
            originalManagerEndVoiceCommand = swizzleVoidMethod(
                on: managerClass,
                selectorName: "endVoiceCommand:",
                replacement: managerEndVoiceCommandBlock
            )
        }

        if let deviceClass = NSClassFromString("BluetoothDevice") {
            let deviceStartVoiceCommandBlock: @convention(block) (AnyObject) -> Void = { object in
                activeMonitor?.handleDeviceVoiceCommand(selectorName: "startVoiceCommand", device: object)

                if let originalDeviceStartVoiceCommand {
                    typealias Function = @convention(c) (AnyObject, Selector) -> Void
                    let function = unsafeBitCast(originalDeviceStartVoiceCommand, to: Function.self)
                    function(object, NSSelectorFromString("startVoiceCommand"))
                }
            }
            originalDeviceStartVoiceCommand = swizzleVoidMethod(
                on: deviceClass,
                selectorName: "startVoiceCommand",
                replacement: deviceStartVoiceCommandBlock
            )

            let deviceEndVoiceCommandBlock: @convention(block) (AnyObject) -> Void = { object in
                activeMonitor?.handleDeviceVoiceCommand(selectorName: "endVoiceCommand", device: object)

                if let originalDeviceEndVoiceCommand {
                    typealias Function = @convention(c) (AnyObject, Selector) -> Void
                    let function = unsafeBitCast(originalDeviceEndVoiceCommand, to: Function.self)
                    function(object, NSSelectorFromString("endVoiceCommand"))
                }
            }
            originalDeviceEndVoiceCommand = swizzleVoidMethod(
                on: deviceClass,
                selectorName: "endVoiceCommand",
                replacement: deviceEndVoiceCommandBlock
            )
        }
    }

    private static func swizzleVoidMethod<Block>(
        on cls: AnyClass,
        selectorName: String,
        replacement block: Block
    ) -> IMP? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(cls, selector) else {
            return nil
        }

        retainedBlocks.append(unsafeBitCast(block, to: AnyObject.self))
        let newImplementation = imp_implementationWithBlock(block)
        return method_setImplementation(method, newImplementation)
    }
}
