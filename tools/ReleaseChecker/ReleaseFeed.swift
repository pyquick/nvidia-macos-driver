import Foundation

struct DriverVersion: Comparable, Sendable {
    let base: [Int]
    private let revision: Int
    private let candidate: Int?

    var isPreview: Bool { candidate != nil }

    init?(_ text: String) {
        guard let match = text.wholeMatch(of: /v?([0-9]+)\.([0-9]+)(?:\.([0-9]+))?(?:-geekaudio\.([0-9]+)(?:-rc([0-9]+)|-ddcci|-stable)?)?/),
              let major = Int(match.1), let minor = Int(match.2),
              let patch = Int(match.3 ?? "0"), let revision = Int(match.4 ?? "0") else { return nil }
        base = [major, minor, patch]
        self.revision = revision
        if let value = match.5 {
            guard let number = Int(value) else { return nil }
            candidate = number
        } else {
            candidate = nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.base != rhs.base { return lhs.base.lexicographicallyPrecedes(rhs.base) }
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        guard let left = lhs.candidate else { return false }
        return rhs.candidate.map { left < $0 } ?? true
    }
}

struct InstalledDriver: Sendable {
    private static let bundlePath = "/Library/Extensions/NVRM.kext"
    let baseline: String
    let releaseTag: String?

    static func read() -> Self? {
        let url = URL(fileURLWithPath: bundlePath + "/Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let baseline = plist["CFBundleVersion"] as? String else { return nil }
        let tag = plist["GeekAudioReleaseTag"] as? String
        return Self(baseline: baseline, releaseTag: tag)
    }

    func status(for release: DriverRelease) -> String {
        guard let current = DriverVersion(baseline) else { return String(localized: "Driver found, but its version is unknown") }
        let available = release.version
        if current.base != available.base {
            return current < available ? String(localized: "Update available") : String(localized: "Installed base version is newer")
        }
        guard let releaseTag, let installed = DriverVersion(releaseTag), installed.base == current.base else {
            return String(localized: "Base versions match. The installed GeekAudio build is unknown.")
        }
        if installed == available { return String(localized: "This version is already installed") }
        return installed < available ? String(localized: "Update available") : String(localized: "Installed build is newer")
    }

    func permits(_ release: DriverRelease) -> Bool {
        guard let current = DriverVersion(baseline), current.base == release.version.base else {
            return DriverVersion(baseline).map { $0 < release.version } ?? false
        }
        guard let releaseTag else { return true }
        return DriverVersion(releaseTag).map { $0.base == current.base && $0 <= release.version } ?? false
    }

    static func permitsInstallation(_ release: DriverRelease) -> Bool {
        if let installed = read() { return installed.permits(release) }
        return !FileManager.default.fileExists(atPath: bundlePath)
    }
}

struct DriverRelease: Sendable {
    let tag: String
    let version: DriverVersion
    let isPreview: Bool
    let offersInstaller: Bool

    var page: URL { ReleaseFeed.repository.appendingPathComponent("releases/tag/\(tag)") }

    static func isFullAsset(_ name: String) -> Bool {
        name.wholeMatch(of: /(?:01-)?geekaudio-nullmoth-[a-z0-9][a-z0-9.-]*-full\.tar\.gz/) != nil
    }
}

enum CheckRoute: String, CaseIterable, Identifiable, Sendable {
    // Preserve the values stored by earlier versions in AppStorage.
    case automatic = "自动回退"
    case direct = "仅 GitHub 直连"
    case proxy = "仅 GitHub 代理"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .automatic: "Automatic fallback"
        case .direct: "GitHub direct only"
        case .proxy: "GitHub proxy only"
        }
    }
}

struct ReleaseFeed: Sendable {
    static let repository = URL(string: "https://github.com/GeekAudio/nvidia-macos-driver")!
    private static let api = "https://api.github.com/repos/GeekAudio/nvidia-macos-driver/releases?per_page=100"
    private static let proxy = "https://gh-proxy.com/"
    private static let withdrawn: Set<String> = ["v2.9-geekaudio.1-rc1", "v2.9.0-geekaudio.1-rc1"]

    private struct Entry: Decodable {
        struct Asset: Decodable { let name: String; let state: String }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    enum FeedError: LocalizedError {
        case http(Int)
        case unexpectedResponse
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .http(let status): "HTTP \(status)"
            case .unexpectedResponse: String(localized: "The server did not return valid release data")
            case .failed(let reason): reason
            }
        }
    }

    let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 9
        self.session = session ?? URLSession(configuration: configuration)
    }

    func check(route: CheckRoute, includePreviews: Bool) async throws -> (release: DriverRelease?, source: String) {
        let direct = (URL(string: Self.api)!, String(localized: "GitHub direct"))
        let proxy = (URL(string: Self.proxy + Self.api)!, String(localized: "Proxy via gh-proxy.com"))
        let routes = switch route {
        case .automatic: [direct, proxy]
        case .direct: [direct]
        case .proxy: [proxy]
        }
        var errors: [String] = []
        for (url, source) in routes {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      http.url?.scheme == "https", http.url?.host == url.host else {
                    throw FeedError.unexpectedResponse
                }
                guard http.statusCode == 200 else { throw FeedError.http(http.statusCode) }
                return (try Self.latest(in: data, includePreviews: includePreviews), source)
            } catch {
                try Task.checkCancellation()
                errors.append("\(source) · \(error.localizedDescription)")
            }
        }
        throw FeedError.failed(errors.joined(separator: "\n"))
    }

    static func latest(in data: Data, includePreviews: Bool) throws -> DriverRelease? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            throw FeedError.unexpectedResponse
        }
        return entries.compactMap { entry -> DriverRelease? in
            guard !entry.draft, !withdrawn.contains(entry.tag_name), entry.tag_name.contains("-geekaudio."),
                  let version = DriverVersion(entry.tag_name),
                  entry.assets.contains(where: {
                      $0.state == "uploaded" && DriverRelease.isFullAsset($0.name)
                  }) else { return nil }
            let preview = entry.prerelease || version.isPreview
            guard !preview || includePreviews else { return nil }
            let names = Set(entry.assets.filter { $0.state == "uploaded" }.map(\.name))
            return DriverRelease(tag: entry.tag_name, version: version, isPreview: preview,
                                 offersInstaller: names.contains("driver-update.json") && names.contains("driver-update.json.sig"))
        }.max { $0.version < $1.version }
    }
}
