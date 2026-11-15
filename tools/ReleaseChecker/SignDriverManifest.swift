import CryptoKit
import Foundation

@main
enum SignDriverManifest {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 2 || args.count == 4,
              let secret = Data(base64Encoded: try String(contentsOfFile: args[1], encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            print("Usage: sign-driver-manifest PRIVATE_KEY [driver-update.json driver-update.json.sig]")
            Foundation.exit(2)
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        if args.count == 2 {
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let manifest = try JSONDecoder().decode(InstallPlan.self, from: bytes)
        let signature = try key.signature(for: bytes)
        _ = try InstallPlan.verify(bytes, signature: signature, tag: manifest.tag, publicKey: key.publicKey.rawRepresentation)
        try signature.write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
    }
}
