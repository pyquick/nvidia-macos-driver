import CryptoKit
import Darwin
import Foundation

struct DriverInstaller: Sendable {
    enum Phase: Sendable {
        case manifest, package, installing

        var title: LocalizedStringResource {
            switch self {
            case .manifest: "Verifying the release signature…"
            case .package: "Downloading and verifying the full installer…"
            case .installing: "Waiting for authorization or installing…"
            }
        }
    }

    static var supportedSystem: Bool {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        return arm64 == 0 && [15, 26].contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    private static let finalHosts: Set<String> = [
        "github.com", "gh-proxy.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"
    ]
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 900
        self.session = session ?? URLSession(configuration: configuration)
    }

    func install(_ release: DriverRelease, route: CheckRoute, phase: @MainActor (Phase) -> Void) async throws -> String {
        guard Self.supportedSystem else { throw InstallError.unsupportedSystem }
        guard release.offersInstaller, InstalledDriver.permitsInstallation(release) else { throw InstallError.versionChanged }
        let key = Data(base64Encoded: InstallerPins.publicKey)!
        await phase(.manifest)
        let plan = try await fetchPlan(release, route: route, key: key)
        guard plan.macOS.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) else {
            throw InstallError.unsupportedSystem
        }

        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("GeekAudioUpdate-\(UUID().uuidString)")
        try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: work) }
        await phase(.package)
        let archive = try await downloadPackage(plan, route: route, directory: work)
        guard InstalledDriver.permitsInstallation(release) else { throw InstallError.versionChanged }
        await phase(.installing)
        return try await Task.detached(priority: .userInitiated) {
            try Self.authorizedInstall(plan, archive: archive)
        }.value
    }

    func fetchPlan(_ release: DriverRelease, route: CheckRoute, key: Data) async throws -> InstallPlan {
        let folder = ReleaseFeed.repository.appendingPathComponent("releases/download/\(release.tag)")
        return try await attempt(folder.appendingPathComponent("driver-update.json"), route: route) { manifest, proxy in
            let signatureURL = folder.appendingPathComponent("driver-update.json.sig")
            return try await attempt(signatureURL, route: proxy ? .proxy : .direct) { signature, _ in
                let bytes = try Self.smallFile(manifest, maximum: 16_384)
                let sig = try Self.smallFile(signature, maximum: 64)
                return try InstallPlan.verify(bytes, signature: sig, tag: release.tag, publicKey: key)
            }
        }
    }

    private func downloadPackage(_ plan: InstallPlan, route: CheckRoute, directory: URL) async throws -> URL {
        let asset = plan.package
        return try await attempt(asset.url(in: ReleaseFeed.repository, tag: plan.tag), route: route) { file, _ in
            guard try Self.size(of: file) == asset.size, try Self.sha256(file) == asset.sha256 else {
                throw InstallError.invalidArchive
            }
            let destination = directory.appendingPathComponent(asset.name)
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
    }

    private func attempt<T: Sendable>(_ url: URL, route: CheckRoute,
                                      consume: (URL, Bool) async throws -> T) async throws -> T {
        let proxy = URL(string: "https://gh-proxy.com/" + url.absoluteString)!
        let routes = switch route {
        case .automatic: [(url, false), (proxy, true)]
        case .direct: [(url, false)]
        case .proxy: [(proxy, true)]
        }
        var failures: [String] = []
        for (candidate, isProxy) in routes {
            try Task.checkCancellation()
            do {
                let (temporary, response) = try await session.download(from: candidate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
                      let host = http.url?.host, Self.finalHosts.contains(host) else { throw ReleaseFeed.FeedError.unexpectedResponse }
                guard http.statusCode == 200 else { throw ReleaseFeed.FeedError.http(http.statusCode) }
                return try await consume(temporary, isProxy)
            } catch {
                try Task.checkCancellation()
                let source = isProxy ? String(localized: "Proxy") : String(localized: "Direct")
                failures.append("\(source) · \(error.localizedDescription)")
            }
        }
        throw InstallError.failed(failures.joined(separator: "\n"))
    }

    private static func size(of file: URL) throws -> Int64 {
        Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
    }

    private static func smallFile(_ file: URL, maximum: Int64) throws -> Data {
        guard try (1...maximum).contains(size(of: file)) else { throw InstallError.invalidPlan }
        return try Data(contentsOf: file)
    }

    private static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func authorizedInstall(_ plan: InstallPlan, archive: URL) throws -> String {
        guard let helper = Bundle.main.url(forResource: "Installer", withExtension: "sh"),
              let bytes = try? Data(contentsOf: helper),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == InstallerPins.helperSHA256,
              let script = String(data: bytes, encoding: .utf8) else { throw InstallError.invalidHelper }
        let arguments = [script, "geekaudio-install", "install", archive.path, plan.package.sha256, plan.tag]
        let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let shell = "set -o pipefail; /usr/bin/env -i /bin/bash --noprofile --norc -c \(quoted) 2>&1 | /usr/bin/tail -c 12000"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        runner.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let output = Pipe()
        runner.standardOutput = output
        runner.standardError = output
        try runner.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        runner.waitUntilExit()
        guard runner.terminationStatus == 0 else {
            if result.contains("(-128)") { throw InstallError.cancelled }
            throw InstallError.failed(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}
