import Foundation
import ServiceManagement

final class StartupManager {
    enum Backend: String {
        case serviceManagement = "SMAppService"
        case launchAgent = "LaunchAgent"
        case disabled = "Disabled"
    }

    func apply(enabled: Bool, bundleID: String, bundleURL: URL) throws -> Backend {
        if enabled {
            if #available(macOS 13.0, *) {
                do {
                    try registerMainApp()
                    return .serviceManagement
                } catch {
                    try installLaunchAgent(bundleID: bundleID, bundleURL: bundleURL)
                    return .launchAgent
                }
            } else {
                try installLaunchAgent(bundleID: bundleID, bundleURL: bundleURL)
                return .launchAgent
            }
        } else {
            if #available(macOS 13.0, *) {
                try? unregisterMainApp()
            }

            try? removeLaunchAgent(bundleID: bundleID)
            return .disabled
        }
    }

    func status(bundleID: String) -> String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return "Enabled via SMAppService"
            case .notRegistered:
                break
            case .requiresApproval:
                return "Needs approval in Login Items"
            case .notFound:
                break
            @unknown default:
                break
            }
        }

        return FileManager.default.fileExists(atPath: launchAgentURL(bundleID: bundleID).path)
            ? "Enabled via LaunchAgent"
            : "Disabled"
    }

    @available(macOS 13.0, *)
    private func registerMainApp() throws {
        try SMAppService.mainApp.register()
    }

    @available(macOS 13.0, *)
    private func unregisterMainApp() throws {
        try SMAppService.mainApp.unregister()
    }

    private func installLaunchAgent(bundleID: String, bundleURL: URL) throws {
        let label = "\(bundleID).login"
        let plistURL = launchAgentURL(bundleID: bundleID)
        let alreadyExists = FileManager.default.fileExists(atPath: plistURL.path)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", bundleURL.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": ["Aqua"]
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        if alreadyExists {
            try? shell(["bootout", "gui/\(getuid())", plistURL.path])
        }
        try shell(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func removeLaunchAgent(bundleID: String) throws {
        let plistURL = launchAgentURL(bundleID: bundleID)
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try? shell(["bootout", "gui/\(getuid())", plistURL.path])
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private func launchAgentURL(bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(bundleID).login.plist")
    }

    private func shell(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "StartupManager", code: Int(process.terminationStatus))
        }
    }
}
