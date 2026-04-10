import Foundation

struct ReleaseVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ rawValue: String) {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.anchored, .caseInsensitive])

        let parts = trimmed
            .split(separator: ".")
            .compactMap { part -> Int? in
                let digits = part.filter(\.isNumber)
                return digits.isEmpty ? nil : Int(digits)
            }

        guard !parts.isEmpty else {
            return nil
        }

        components = parts
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

struct ReleaseAssetInfo: Equatable {
    let name: String
    let downloadURL: URL
}

struct ReleaseInfo: Equatable {
    let tagName: String
    let version: ReleaseVersion
    let title: String
    let htmlURL: URL
    let asset: ReleaseAssetInfo
    let publishedAt: Date?
}

enum ReleaseUpdaterError: LocalizedError {
    case invalidResponse
    case unsupportedInstallContext
    case noCompatibleAsset
    case unpackFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub Releases returned an invalid response."
        case .unsupportedInstallContext:
            return "Updates only work when OnBlast is running from a built .app bundle."
        case .noCompatibleAsset:
            return "No compatible macOS release asset was found."
        case .unpackFailed(let details):
            return details.isEmpty ? "The downloaded update could not be unpacked." : details
        case .installFailed(let details):
            return details.isEmpty ? "The update install failed." : details
        }
    }
}

final class ReleaseUpdater: @unchecked Sendable {
    var onLog: ((String) -> Void)?

    private let session: URLSession
    private let fileManager = FileManager.default
    private let repoOwner = "gieseking"
    private let repoName = "OnBlast"
    private let releaseAssetPrefix = "OnBlast-"
    private let releaseAssetSuffix = "-macOS.zip"

    init(session: URLSession = .shared) {
        self.session = session
    }

    var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var currentBuildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var currentBundlePath: String {
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.pathExtension == "app" ? bundleURL.path : "Unavailable outside .app bundle"
    }

    func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OnBlast/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw ReleaseUpdaterError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GitHubReleasePayload.self, from: data)
        guard let version = ReleaseVersion(payload.tagName) else {
            throw ReleaseUpdaterError.invalidResponse
        }

        guard let asset = payload.bestMatchingAsset(prefix: releaseAssetPrefix, suffix: releaseAssetSuffix) else {
            throw ReleaseUpdaterError.noCompatibleAsset
        }

        return ReleaseInfo(
            tagName: payload.tagName,
            version: version,
            title: payload.name ?? payload.tagName,
            htmlURL: payload.htmlURL,
            asset: ReleaseAssetInfo(name: asset.name, downloadURL: asset.browserDownloadURL),
            publishedAt: payload.publishedAt
        )
    }

    func installRelease(_ release: ReleaseInfo, over bundleURL: URL, currentProcessID: Int32) async throws {
        guard bundleURL.pathExtension == "app" else {
            throw ReleaseUpdaterError.unsupportedInstallContext
        }

        onLog?("Downloading release asset \(release.asset.name) from GitHub Releases")
        var downloadRequest = URLRequest(url: release.asset.downloadURL)
        downloadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        downloadRequest.setValue("OnBlast/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let (downloadedArchiveURL, response) = try await session.download(for: downloadRequest)

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw ReleaseUpdaterError.invalidResponse
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("OnBlastUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let archiveURL = stagingRoot.appendingPathComponent(release.asset.name, isDirectory: false)
        try fileManager.moveItem(at: downloadedArchiveURL, to: archiveURL)

        let expandedDirectoryURL = stagingRoot.appendingPathComponent("expanded", isDirectory: true)
        try fileManager.createDirectory(at: expandedDirectoryURL, withIntermediateDirectories: true)
        try runProcess(
            executablePath: "/usr/bin/ditto",
            arguments: ["-x", "-k", archiveURL.path, expandedDirectoryURL.path],
            errorBuilder: ReleaseUpdaterError.unpackFailed
        )

        guard let stagedAppURL = findAppBundle(named: "\(repoName).app", under: expandedDirectoryURL) else {
            throw ReleaseUpdaterError.unpackFailed("The downloaded release did not contain \(repoName).app.")
        }

        onLog?("Staged update \(release.version.description) for installation over \(bundleURL.path)")
        try scheduleReplacement(
            stagedAppURL: stagedAppURL,
            destinationAppURL: bundleURL,
            cleanupDirectoryURL: stagingRoot,
            currentProcessID: currentProcessID
        )
    }

    private func findAppBundle(named appBundleName: String, under directoryURL: URL) -> URL? {
        if directoryURL.lastPathComponent == appBundleName, directoryURL.pathExtension == "app" {
            return directoryURL
        }

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let candidateURL as URL in enumerator {
            if candidateURL.lastPathComponent == appBundleName, candidateURL.pathExtension == "app" {
                return candidateURL
            }
        }

        return nil
    }

    private func scheduleReplacement(
        stagedAppURL: URL,
        destinationAppURL: URL,
        cleanupDirectoryURL: URL,
        currentProcessID: Int32
    ) throws {
        let installerScriptURL = cleanupDirectoryURL.appendingPathComponent("install-update.sh", isDirectory: false)
        let scriptContents = updateInstallerScript(
            stagedAppURL: stagedAppURL,
            destinationAppURL: destinationAppURL,
            cleanupDirectoryURL: cleanupDirectoryURL,
            currentProcessID: currentProcessID
        )
        try scriptContents.write(to: installerScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installerScriptURL.path)

        let parentDirectory = destinationAppURL.deletingLastPathComponent()
        let needsPrivilegeEscalation = !fileManager.isWritableFile(atPath: parentDirectory.path)

        if needsPrivilegeEscalation {
            let shellCommand = "/usr/bin/nohup \(shellQuoted(installerScriptURL.path)) >/tmp/onblast-updater.log 2>&1 &"
            try runPrivilegedShell(shellCommand: shellCommand)
        } else {
            try launchBackgroundShellCommand("/usr/bin/nohup \(shellQuoted(installerScriptURL.path)) >/tmp/onblast-updater.log 2>&1 &")
        }
    }

    private func updateInstallerScript(
        stagedAppURL: URL,
        destinationAppURL: URL,
        cleanupDirectoryURL: URL,
        currentProcessID: Int32
    ) -> String {
        """
        #!/bin/sh
        set -eu

        pid='\(currentProcessID)'
        src=\(shellQuoted(stagedAppURL.path))
        dst=\(shellQuoted(destinationAppURL.path))
        cleanup=\(shellQuoted(cleanupDirectoryURL.path))

        count=0
        while /bin/kill -0 "$pid" >/dev/null 2>&1; do
          /bin/sleep 0.25
          count=$((count + 1))
          if [ "$count" -ge 240 ]; then
            break
          fi
        done

        /bin/rm -rf "$dst"
        /usr/bin/ditto "$src" "$dst"
        /usr/bin/xattr -dr com.apple.quarantine "$dst" >/dev/null 2>&1 || true
        /usr/bin/open "$dst"
        /bin/rm -rf "$cleanup"
        /bin/rm -f "$0"
        """
    }

    private func launchBackgroundShellCommand(_ shellCommand: String) throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand]
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ReleaseUpdaterError.installFailed(errorOutput)
        }
    }

    private func runPrivilegedShell(shellCommand: String) throws {
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
            throw ReleaseUpdaterError.installFailed(details)
        }
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        errorBuilder: (String) -> ReleaseUpdaterError
    ) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
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
            throw errorBuilder(details)
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

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [GitHubReleaseAssetPayload]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    func bestMatchingAsset(prefix: String, suffix: String) -> GitHubReleaseAssetPayload? {
        if let exact = assets.first(where: { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(suffix) }) {
            return exact
        }

        return assets.first(where: { $0.name.localizedCaseInsensitiveContains("OnBlast") && $0.name.lowercased().hasSuffix(".zip") })
    }
}

private struct GitHubReleaseAssetPayload: Decodable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
