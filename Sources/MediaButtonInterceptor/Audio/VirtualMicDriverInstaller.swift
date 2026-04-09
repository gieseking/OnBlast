import Foundation

enum VirtualMicDriverInstallerError: LocalizedError {
    case appBundleRequired
    case bundledDriverMissing
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .appBundleRequired:
            return "The virtual mic driver installer only works from the built .app bundle."
        case .bundledDriverMissing:
            return "The built app bundle does not contain a virtual mic driver payload."
        case .installFailed(let details):
            return details.isEmpty ? "The virtual mic driver install failed." : details
        }
    }
}

final class VirtualMicDriverInstaller: @unchecked Sendable {
    var onLog: ((String) -> Void)?

    private let fileManager = FileManager.default
    private let driverBundleName = "MediaButtonVirtualAudioPlugIn.driver"
    private let xpcBundleName = "MediaButtonVirtualAudioXPC.xpc"
    private let driverInstallRoot = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)

    var bundledDriverURL: URL? {
        bundledAssetURL(named: driverBundleName)
    }

    var bundledXPCURL: URL? {
        bundledAssetURL(named: xpcBundleName)
    }

    var installedDriverURL: URL {
        driverInstallRoot.appendingPathComponent(driverBundleName, isDirectory: true)
    }

    func isBundledDriverAvailable() -> Bool {
        guard let bundledDriverURL else {
            return false
        }

        return fileManager.fileExists(atPath: bundledDriverURL.path)
    }

    func isInstalled() -> Bool {
        fileManager.fileExists(atPath: installedDriverURL.path)
    }

    func installBundledDriver() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw VirtualMicDriverInstallerError.appBundleRequired
        }

        guard let bundledDriverURL, fileManager.fileExists(atPath: bundledDriverURL.path) else {
            throw VirtualMicDriverInstallerError.bundledDriverMissing
        }

        let bundledXPCURL = bundledXPCURL
        onLog?("Installing bundled virtual mic driver into \(driverInstallRoot.path)")
        if bundledXPCURL != nil {
            onLog?("Bundled virtual mic XPC payload was found and will be installed inside the driver bundle")
        }

        let shellCommand = installShellCommand(
            bundledDriverURL: bundledDriverURL,
            bundledXPCURL: bundledXPCURL,
            installedDriverURL: installedDriverURL
        )
        try runPrivilegedInstall(shellCommand: shellCommand)
        onLog?("Virtual mic driver install finished; Core Audio was asked to reload")
    }

    private func bundledAssetURL(named assetName: String) -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("VirtualAudioDriver", isDirectory: true)
            .appendingPathComponent(assetName, isDirectory: true)
    }

    private func installShellCommand(
        bundledDriverURL: URL,
        bundledXPCURL: URL?,
        installedDriverURL: URL
    ) -> String {
        var commands = [
            "/bin/mkdir -p \(shellQuoted(driverInstallRoot.path))",
            "/bin/rm -rf \(shellQuoted(installedDriverURL.path))",
            "/usr/bin/ditto \(shellQuoted(bundledDriverURL.path)) \(shellQuoted(installedDriverURL.path))"
        ]

        if let bundledXPCURL, fileManager.fileExists(atPath: bundledXPCURL.path) {
            let xpcInstallDirectory = installedDriverURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("XPCServices", isDirectory: true)
            let installedXPCURL = xpcInstallDirectory.appendingPathComponent(xpcBundleName, isDirectory: true)

            commands.append("/bin/mkdir -p \(shellQuoted(xpcInstallDirectory.path))")
            commands.append("/bin/rm -rf \(shellQuoted(installedXPCURL.path))")
            commands.append("/usr/bin/ditto \(shellQuoted(bundledXPCURL.path)) \(shellQuoted(installedXPCURL.path))")
        }

        commands.append("/usr/sbin/chown -R root:wheel \(shellQuoted(installedDriverURL.path))")
        commands.append("/bin/chmod -R go-w \(shellQuoted(installedDriverURL.path))")
        commands.append("/usr/bin/killall coreaudiod >/dev/null 2>&1 || true")
        return commands.joined(separator: " && ")
    }

    private func runPrivilegedInstall(shellCommand: String) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptQuoted(shellCommand)) with administrator privileges"
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let standardOutput = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let details = [errorOutput, standardOutput]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            throw VirtualMicDriverInstallerError.installFailed(details)
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
