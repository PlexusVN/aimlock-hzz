import Foundation
import CryptoKit
import Security

// Shared by the iOS app and offline macOS security checks. Keep this file
// independent of UIKit and application identity/network-session dependencies.
enum AstraServerTrust {
    // Keep the production origin out of the plaintext string table. This is a
    // static-analysis speed bump only; trust still comes from the certificate
    // pin and signed server protocol below.
    static let protectedHost = decode([
        198, 206, 202, 203, 200, 196, 204, 207, 221, 221, 137, 212, 206, 211, 194
    ], 0xA7)
    static let protectedOrigin = decode([
        207, 211, 211, 215, 212, 157, 136, 136, 198, 206, 202, 203, 200, 196, 204, 207, 221, 221, 137, 212, 206, 211, 194
    ], 0xA7)

    // Legacy offline leaf-only checker: full certificate DER hash verified
    // with normal system trust for aimlockhzz.site on 2026-11-14. The compiled
    // iOS delegate additionally accepts the verified YE2 intermediate.
    static let leafCertificatePins: Set<String> = [
        "SjzSZU44vxnR21HP6KwHfgfMQGx76tNxVt9eliXroMk="
    ]

    static func accepts(_ trust: SecTrust, host: String) -> Bool {
        guard host.caseInsensitiveCompare(protectedHost) == .orderedSame else { return false }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else { return false }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return false }
        let der = SecCertificateCopyData(leaf) as Data
        return leafCertificatePins.contains(Data(SHA256.hash(data: der)).base64EncodedString())
    }

    private static func decode(_ data: [UInt8], _ key: UInt8) -> String {
        String(decoding: data.map { $0 ^ key }, as: UTF8.self)
    }
}
