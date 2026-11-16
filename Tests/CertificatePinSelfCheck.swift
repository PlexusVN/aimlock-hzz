import Foundation

@main struct CertificatePinSelfCheck {
    static func main() {
        precondition(AppSecurityConfiguration.permitsCertificatePins([AppSecurityConfiguration.tlsLeafPin]))
        precondition(AppSecurityConfiguration.permitsCertificatePins([
            "new-leaf", "l2WN6MaN+pis4eUCimPVShqukRs+IUcQdsaFDNCMurQ="]))
        for rootPin in ["D8CQHMorrp6f27AtUNAvEJT3s2ZyCGmRueiXYm3EhfA=",
                        "7l96vWmBuwJVYyzY9JKDRRtLGIRNEgQLRO4A8HuP4sY="] {
            precondition(!AppSecurityConfiguration.permitsCertificatePins([rootPin]))
        }
        precondition(!AppSecurityConfiguration.permitsCertificatePins([]))
        precondition(!AppSecurityConfiguration.permitsCertificatePins(["proxy-leaf", "user-installed-root"]))
        precondition(!AppSecurityConfiguration.permitsCertificatePins([
            "7NfgIVpP+fdJQCMiloG7ljIWxP5OZEiAGfsc6+jgcQA=",
            "HfwWBfutNY2LyET3bRUgP6ycpcGnn9SFf/ryhk++v5Y="]))
        precondition(!AppSecurityConfiguration.permitsCertificatePins([
            "69QQQOS7PsdCyeOB0x7ypBpItmhclufO88HfbNQzHJk="]))
        print("[PASS] current leaf/YE2 renewal accepted; unknown/user/root-only chain denied")
        for variant in ["ffth", "ffmax", "capcut", "generic", "unknown", "", "Generic", "ffth "] {
            for kind in ["package", "mod", "original", "unknown", "", "Package"] {
                let expected = (kind == "package" && ["ffth", "ffmax", "capcut", "generic"].contains(variant))
                    || (["mod", "original"].contains(kind) && ["ffth", "ffmax"].contains(variant))
                precondition(AppSecurityConfiguration.supportsProtectedArtifact(variant: variant, kind: kind) == expected,
                             "Invalid protected artifact support: \(variant)/\(kind)")
            }
        }
        precondition(AppSecurityConfiguration.protectedBundleID(forVariant: "generic") == nil,
                     "Generic protocol metadata must not invent a fixed Bundle ID")
        print("[PASS] generic is package-only; native variants and legacy Bundle ID mapping remain bounded")
    }
}
