import Foundation

/// Production public configuration. Private signing/master keys stay on the server.
enum AppSecurityConfiguration {
    // Owner-selected network-only client policy. ESign/KSign installs need no
    // release seal, App Store receipt, Team ID, debugger or jailbreak checks.
    // Server key/session/proof authorization and encrypted delivery stay on.
    static let localIntegrityEnforced = false
    static let apiOrigin = "https://aimlockhzz.site"
    static let apiHost = "aimlockhzz.site"
    static let tlsLeafPin = "SjzSZU44vxnR21HP6KwHfgfMQGx76tNxVt9eliXroMk="
    // SHA-256 of the exact public certificate DER, verified through normal
    // system trust and hostname validation for aimlockhzz.site on 2026-11-14.
    // Pin the current leaf and its YE2 intermediate, never Root YE/X2/X1.
    static let tlsCertificatePins: Set<String> = [
        tlsLeafPin,
        "l2WN6MaN+pis4eUCimPVShqukRs+IUcQdsaFDNCMurQ="
    ]
    static func permitsCertificatePins(_ pins: [String]) -> Bool {
        !tlsCertificatePins.isDisjoint(with: pins)
    }
    static let signingKeyId = "astra-rsa-2026-01"
    static let signingPublicKeyPKCS1Base64 = "MIIBCgKCAQEAxF0kg3/mMZY//nPiXgj7YnZEEDJ0aiDdiNfw3cUgJfxeeBmA6+1C51Xd/fX3rI6zoIDzjt9o+Dmb/YiySHBEBwyicCXC1zeEF9m3Jo5ybaS5sEgQvUWF0v4QM8CoEuj3hGzgNDfOwRrWBcPSrPzEJTsjcUt8X/azC5MVFgVV6maJHcV1MH/i7ywzkNH7CtU1p246PQEg1KyF89kHbpWa0N8/D/DDeG5viLKlB4OxBlm/ZVDITaWqGoRVlq8QuuXUCfdHOY2Rl7I3P/bT0Wsmibek0RSUnmEW+AzUsEbqK882hbjHS4JPMIE4YViuhxMF9gqHiQ65pHrxCenGP5nXUwIDAQAB"
    static let productSecret = "aimlock-hzz"
    static var isConfigured: Bool { true }
    /// Preparation targets derive from the same catalog capability map.
    static var protectedBundleIDs: [String] {
        ["ffth", "ffmax", "capcut"].compactMap { protectedBundleID(forVariant: $0) }.sorted()
    }
    static func protectedBundleID(forVariant variant: String) -> String? {
        switch variant {
        case "ffth": return "com.dts.freefireth"
        case "ffmax": return "com.dts.freefiremax"
        case "capcut": return "com.lemon.lvoverseas"
        default: return nil
        }
    }
}
