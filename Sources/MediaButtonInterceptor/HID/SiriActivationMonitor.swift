import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

final class SiriActivationMonitor: @unchecked Sendable {
    var onButtonEvent: ((ButtonEvent) -> Bool)?
    var onLog: ((String) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var suppressNotificationsUntil = Date.distantPast
    private var isEnabled = false
    private var runToken: UInt64 = 0

    private let handledPressSuppressionInterval: TimeInterval = 0.5
    private let siriBundleIdentifiers: Set<String> = [
        "com.apple.Siri",
        "com.apple.siri.launcher"
    ]

    func start(enabled: Bool) {
        stop()

        guard enabled else {
            return
        }

        isEnabled = true
        let token = runToken

        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] in
                self?.handle(notification: $0, reason: "activated", token: token)
            }
        )
        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] in
                self?.handle(notification: $0, reason: "launched", token: token)
            }
        )

        onLog?("Siri activation fallback started")
    }

    func stop() {
        isEnabled = false
        runToken &+= 1
        suppressNotificationsUntil = Date.distantPast

        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func dismissActiveSiri(reason: String) {
        onLog?("Requesting Siri dismissal (\(reason))")
        let token = runToken
        dismissSiri(processIdentifier: 0, token: token)
    }

    private func handle(notification: Notification, reason: String, token: UInt64) {
        guard isEnabled, token == runToken else {
            return
        }

        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let bundleIdentifier = application.bundleIdentifier,
            siriBundleIdentifiers.contains(bundleIdentifier)
        else {
            return
        }

        let now = Date()
        if now < suppressNotificationsUntil {
            return
        }

        let processIdentifier = application.processIdentifier
        onLog?("Observed Siri activation (\(reason)) from \(bundleIdentifier)")

        let event = ButtonEvent(
            button: .voiceCommand,
            isDown: true,
            isRepeat: false,
            source: .siriActivation,
            deviceName: bundleIdentifier,
            rawDescription: "reason=\(reason) bundleID=\(bundleIdentifier)"
        )

        let wasHandled = onButtonEvent?(event) ?? false
        guard wasHandled else {
            onLog?("Voice command is passthrough, leaving Siri open")
            return
        }

        suppressNotificationsUntil = now.addingTimeInterval(handledPressSuppressionInterval)
        dismissSiri(processIdentifier: processIdentifier, token: token)
    }

    private func dismissSiri(processIdentifier: pid_t, token: UInt64) {
        guard token == runToken else {
            return
        }

        onLog?("Dismissing Siri and forwarding voice-command action")

        // Siri activation tends to race UI launch and focus changes, so dismiss it
        // immediately and then retry a couple of times to keep repeated presses responsive.
        performDismissAttempt(processIdentifier: processIdentifier, attempt: 0, token: token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.performDismissAttempt(processIdentifier: processIdentifier, attempt: 1, token: token)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.performDismissAttempt(processIdentifier: processIdentifier, attempt: 2, token: token)
        }
    }

    private func performDismissAttempt(processIdentifier: pid_t, attempt: Int, token: UInt64) {
        guard token == runToken else {
            return
        }

        postEscape()

        let targets = siriApplications(processIdentifier: processIdentifier)
        guard !targets.isEmpty else {
            return
        }

        for application in targets {
            _ = application.hide()

            if attempt >= 2 {
                _ = application.forceTerminate()
            } else {
                _ = application.terminate()
            }
        }
    }

    private func siriApplications(processIdentifier: pid_t) -> [NSRunningApplication] {
        let runningSiriApps = NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return false
            }

            return siriBundleIdentifiers.contains(bundleIdentifier)
        }

        if runningSiriApps.isEmpty, let application = NSRunningApplication(processIdentifier: processIdentifier) {
            return [application]
        }

        return runningSiriApps
    }

    private func postEscape() {
        EventInjectionGuard.shared.beginSyntheticBurst()
        let source = CGEventSource(stateID: .hidSystemState)

        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: isDown) else {
                continue
            }

            event.post(tap: .cghidEventTap)
        }
    }
}
