import AppKit
import SwiftUI

@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var hostingController: NSViewController?
    private var onVisibilityChange: ((Bool) -> Void)?

    func setVisibilityChangeHandler(_ handler: @escaping (Bool) -> Void) {
        onVisibilityChange = handler
    }

    func show(model: AppModel) {
        if let window {
            onVisibilityChange?(true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsView()
            .environmentObject(model)

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 760)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "OnBlast Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("OnBlastSettingsWindow")
        window.delegate = self

        self.window = window
        self.hostingController = hostingController
        onVisibilityChange?(true)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hostingController = nil
        onVisibilityChange?(false)
    }
}
