import AppKit
import CoreGraphics
import Foundation

final class SystemDefinedEventTap {
    var onButtonEvent: ((ButtonEvent) -> Bool)?
    var onLog: ((String) -> Void)?

    private let systemDefinedRawType: UInt64 = 14
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start(enabled: Bool) {
        stop()

        guard enabled else {
            return
        }

        let mask = (1 as CGEventMask) << systemDefinedRawType
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else {
                return Unmanaged.passUnretained(event)
            }

            let listener = Unmanaged<SystemDefinedEventTap>.fromOpaque(context).takeUnretainedValue()
            return listener.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            onLog?("Failed to create system-defined event tap. Accessibility permission is probably missing.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        onLog?("System-defined event tap started")
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        runLoopSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                onLog?("Re-enabled system-defined event tap")
            }

            return Unmanaged.passUnretained(event)
        }

        if EventInjectionGuard.shared.shouldIgnoreSyntheticEvents {
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        if let decoded = InputEventDecoding.decodeSystemDefined(nsEvent) {
            onLog?(
                "Observed system-defined event: button=\(decoded.button.displayName) state=\(decoded.isDown ? "down" : "up") repeat=\(decoded.isRepeat ? "yes" : "no") raw={\(decoded.rawDescription)}"
            )
            let shouldConsume = onButtonEvent?(decoded) ?? false
            if shouldConsume && decoded.isDown {
                onLog?("Consumed system-defined event: \(decoded.button.displayName)")
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        if let rawDescription = InputEventDecoding.rawSystemDefinedDescription(nsEvent) {
            onLog?("Observed unknown system-defined event: \(rawDescription)")
        }

        return Unmanaged.passUnretained(event)
    }
}
