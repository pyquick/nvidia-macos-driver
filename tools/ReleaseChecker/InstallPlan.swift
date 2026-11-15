import CryptoKit
import Foundation

struct InstallPlan: Codable, Sendable {
    struct Archive: Codable, Sendable {
        let name: String
        let sha256: String
        let size: Int64

        var isValid: Bool {
            DriverRelease.isFullAsset(name) &&
            sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil && (1...1_500_000_000).contains(size)
        }

        func url(in repo: URL, tag: String) -> URL { repo.appendingPathComponent("releases/download/\(tag)/\(name)") }
    }

    let schema: String
    let tag: String
    let macOS: [Int]
    let package: Archive

    var isValid: Bool {
        schema == "GeekAudio/NullMoth/install/v2" && DriverVersion(tag) != nil && tag.contains("-geekaudio.") &&
        !macOS.isEmpty && macOS.allSatisfy { $0 == 15 || $0 == 26 } && package.isValid
    }

    static func verify(_ bytes: Data, signature: Data, tag: String, publicKey: Data) throws -> Self {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: bytes) else { throw InstallError.invalidSignature }
        let plan = try JSONDecoder().decode(Self.self, from: bytes)
        guard plan.isValid, plan.tag == tag else { throw InstallError.invalidPlan }
        return plan
    }
}

enum InstallError: LocalizedError {
    case invalidSignature, invalidPlan, unsupportedSystem, versionChanged, invalidArchive, invalidHelper, cancelled, failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSignature: String(localized: "The release signature could not be verified.")
        case .invalidPlan: String(localized: "The install manifest is invalid or does not match the selected release.")
        case .unsupportedSystem: String(localized: "This package does not support this Mac’s processor or macOS version.")
        case .versionChanged: String(localized: "The installed version changed. Check for updates again.")
        case .invalidArchive: String(localized: "The download size or SHA-256 does not match the release manifest.")
        case .invalidHelper: String(localized: "The installer component failed verification. Download the app again.")
        case .cancelled: String(localized: "Installation canceled.")
        case .failed(let message): message
        }
    }
}
