import AppKit
import Combine
import Foundation

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var observation: AnyCancellable?

    private let appTitleItem = NSMenuItem(title: "OnBlast", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var toggleMuteItem = NSMenuItem(
        title: "",
        action: #selector(toggleMuteFromMenu),
        keyEquivalent: ""
    )
    private lazy var openSettingsItem = NSMenuItem(
        title: "Open Settings",
        action: #selector(openSettings),
        keyEquivalent: ""
    )
    private lazy var quitItem = NSMenuItem(
        title: "Quit",
        action: #selector(quitApp),
        keyEquivalent: ""
    )

    init(model: AppModel) {
        self.model = model
        super.init()
        configureStatusItem()
        configureMenu()
        observeModel()
        refresh()
    }

    func start() {
        refresh()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("OnBlast")
    }

    private func configureMenu() {
        menu.delegate = self

        appTitleItem.isEnabled = false
        stateItem.isEnabled = false

        toggleMuteItem.target = self
        openSettingsItem.target = self
        quitItem.target = self

        menu.items = [
            appTitleItem,
            stateItem,
            .separator(),
            toggleMuteItem,
            .separator(),
            openSettingsItem,
            quitItem
        ]
    }

    private func observeModel() {
        observation = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSoon()
            }
    }

    private func refreshSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let button = statusItem.button else {
            return
        }

        button.image = StatusBarIconFactory.image(for: model.micState)
        button.title = model.config.menuBarTitle
        button.toolTip = "OnBlast: \(model.micState.displayName)"

        stateItem.title = "Mic: \(model.micState.displayName)"
        toggleMuteItem.title = model.micState == .muted ? "Unmute Microphone" : "Mute Microphone"
        toggleMuteItem.isEnabled = model.canToggleMicMute
    }

    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            model.toggleMicMute()
            return
        }

        let isRightClick = event.type == .rightMouseUp ||
            (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isRightClick {
            showContextMenu()
        } else {
            guard model.canToggleMicMute else {
                return
            }
            model.toggleMicMute()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else {
            return
        }

        refresh()
        statusItem.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        statusItem.button?.highlight(false)
    }

    @objc
    private func toggleMuteFromMenu() {
        guard model.canToggleMicMute else {
            return
        }
        model.toggleMicMute()
    }

    @objc
    private func openSettings() {
        model.openSettingsWindow()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }
}
