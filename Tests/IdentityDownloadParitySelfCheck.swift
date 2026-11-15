import Foundation

enum DeviceIdentityError: Error { case identityMissing, invalidIdentity, ambiguousIdentity, keychain(Int32) }
enum ProtectedDownloadError: Error { case invalidResponse, rejected(String) }
enum BoundaryFailure: Error { case transient, failed(String) }
enum FeaturePatchError: Error { case notAuthenticated }

@MainActor enum IdentityFixture {
    static var legacyError: Error?, scopedError: Error?
    static var posts = 0, migrations = 0
    static func reset() { legacyError = nil; scopedError = nil; posts = 0; migrations = 0 }
}
@MainActor final class AuthManager {}
@MainActor final class ProtectedAuthContext {
    let binding = "new-scope"
    var valid = true
    init(_ auth: AuthManager) {}
    init() {}
    func validate() throws { guard valid else { throw FeaturePatchError.notAuthenticated } }
}
@MainActor final class DeviceIdentityService {
    static let shared = DeviceIdentityService(binding: nil)
    let licenseBinding: String?
    init(binding: String?) { licenseBinding = binding }
    static func scoped(to binding: String) throws -> DeviceIdentityService { DeviceIdentityService(binding: binding) }
    func persistedEnrollmentID() throws -> String? {
        if licenseBinding == nil, let error = IdentityFixture.legacyError { throw error }
        if licenseBinding != nil, let error = IdentityFixture.scopedError { throw error }
        return nil
    }
    func migrateLegacy(to binding: String, expectedDeviceID: String, keyID: Int) throws { IdentityFixture.migrations += 1 }
}
@MainActor final class PreparationHarness {
    var identity: DeviceIdentityService?
    func run(_ context: ProtectedAuthContext? = nil) async throws -> DeviceIdentityService {
        try await prepareIdentity(context ?? ProtectedAuthContext())
    }
    private func post(_ route: String, body: [String: String], signed: Bool, purpose: String,
                      bearer: Bool, identityOverride: DeviceIdentityService) async throws -> (Data, String) {
        IdentityFixture.posts += 1
        throw BoundaryFailure.failed("unexpected global migration request")
    }
    private func dictionary(_ data: Data) throws -> [String: Any] { [:] }
    // ACTUAL_PREPARE_IDENTITY
}

struct PatchItem {
    let artifactID: String? = "artifact"
    let manifestDigest: String? = "manifest"
    let artifactVariant: String? = "fixture"
    let fileHash = "hash", fileSize = 0, version = 1
}
struct ProtectedArtifactDescriptor {
    let artifactID: String, fileHash: String, fileSize: Int, version: Int64
    let manifestDigest: String, variant: String, kind: String, fileName: String?
}
actor DownloadGate {
    var releases = 0
    func acquire() {}
    func release() { releases += 1 }
}
@MainActor final class DownloadHarness {
    let gate = DownloadGate()
    var currentAuthContext: ProtectedAuthContext?
    var cachedSession = true, clearCount = 0, downloadCount = 0, bootstrapCount = 0
    var failure: Error = DeviceIdentityError.invalidIdentity
    var invalidateContextDuringDownload = false
    var accessNotice: String?
    func run() async {
        do { _ = try await download(PatchItem(), auth: AuthManager()) } catch { }
    }
    private func beginOperation(_ context: ProtectedAuthContext) throws { currentAuthContext = context }
    private func ensureSession(auth: AuthManager) async throws {
        if !cachedSession { bootstrapCount += 1; cachedSession = true }
    }
    private func ensureReleaseLease() async throws {}
    private func clearSession() { clearCount += 1; cachedSession = false }
    private func downloadArtifact(_ descriptor: ProtectedArtifactDescriptor, auth: AuthManager) async throws -> (data: Data, fileName: String) {
        downloadCount += 1
        if invalidateContextDuringDownload { currentAuthContext?.valid = false }
        throw failure
    }
    // ACTUAL_LOCAL_IDENTITY_FAILURE
    // ACTUAL_DOWNLOAD
}

@main enum IdentityDownloadParitySelfCheck {
    @MainActor static var checks = 0
    @MainActor static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw BoundaryFailure.failed(label) }; checks += 1
    }
    @MainActor static func main() async throws {
        for error in [DeviceIdentityError.identityMissing, .invalidIdentity] {
            IdentityFixture.reset(); IdentityFixture.legacyError = error
            let flow = PreparationHarness(), selected = try await flow.run()
            try require(selected.licenseBinding == "new-scope" && flow.identity === selected,
                        "invalid unrelated global archive blocked selected scope")
            try require(IdentityFixture.posts == 0 && IdentityFixture.migrations == 0,
                        "unrelated invalid legacy archive triggered a request or replacement")
        }
        for error in [DeviceIdentityError.keychain(-25308), .keychain(-34018)] {
            IdentityFixture.reset(); IdentityFixture.legacyError = error
            let flow = PreparationHarness()
            do { _ = try await flow.run(); throw BoundaryFailure.failed("storage access error was swallowed") }
            catch DeviceIdentityError.keychain { }
            try require(flow.identity == nil && IdentityFixture.posts == 0 && IdentityFixture.migrations == 0,
                        "locked/entitlement error modified scope or archive")
        }
        IdentityFixture.reset(); IdentityFixture.scopedError = DeviceIdentityError.invalidIdentity
        let invalidScope = PreparationHarness()
        do { _ = try await invalidScope.run(); throw BoundaryFailure.failed("invalid selected scope was swallowed") }
        catch DeviceIdentityError.invalidIdentity { }
        try require(invalidScope.identity == nil, "selected scope corruption cached an identity")
        IdentityFixture.reset()
        let stale = ProtectedAuthContext(); stale.valid = false
        let canceledPreparation = PreparationHarness()
        do { _ = try await canceledPreparation.run(stale); throw BoundaryFailure.failed("invalid context published identity") }
        catch FeaturePatchError.notAuthenticated { }
        try require(canceledPreparation.identity == nil, "invalid context published selected identity")

        for failure in [DeviceIdentityError.identityMissing, .invalidIdentity] {
            let flow = DownloadHarness(); flow.failure = failure
            await flow.run()
            try require(!flow.cachedSession && flow.clearCount == 1 && flow.downloadCount == 1 && flow.bootstrapCount == 0,
                        "local identity failure did not clear session exactly once without replay")
            await flow.run()
            try require(flow.downloadCount == 2 && flow.bootstrapCount == 1,
                        "next explicit operation did not bootstrap once")
            try require(await flow.gate.releases == 2, "failed downloads retained the operation gate")
        }
        let transient = DownloadHarness(); transient.failure = BoundaryFailure.transient
        await transient.run()
        try require(transient.cachedSession && transient.clearCount == 0 && transient.bootstrapCount == 0,
                    "transient failure invalidated usable session")
        let canceled = DownloadHarness(); canceled.failure = CancellationError()
        await canceled.run()
        try require(canceled.cachedSession && canceled.clearCount == 0, "cancellation became identity failure")
        let obsolete = DownloadHarness(); obsolete.invalidateContextDuringDownload = true
        await obsolete.run()
        try require(obsolete.cachedSession && obsolete.clearCount == 0,
                    "failure from invalid context cleared another session")
        print("Production identity preparation/download recovery: \(checks) checks passed")
    }
}
