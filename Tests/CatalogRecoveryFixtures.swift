// Only external transport/OS boundaries are fixtures. The runner extracts the
// unchanged production catalog methods, registry, gate and provenance store.
enum CatalogCheckError: Error { case failed(String), writeFailure }
enum FeaturePatchError: Error { case notAuthenticated }
enum ProtectedDownloadError: Error { case invalidResponse }
enum WorseQueryError: Error { case unsupportedOS(String) }
enum PatchPackageError: Error { case restoreTargetsChanged([String]), symbolicLinkUnsupported }
enum PatchOperationStage: String { case download, decode, target, access, write }
struct PatchOperationError: Error {
    let stage: PatchOperationStage
    let underlying: Error
    static func wrap(_ error: Error, at: PatchOperationStage) -> Self { Self(stage:at,underlying:error) }
}
struct PatchItem { let id:Int; let name:String; let slug:String; var artifactVariant:String?="fixture" }
struct Target { var bundleID:String;var relativePath:String }
struct PatchProject {
    var id=UUID();var isPrivate=false
    var allBundleIdentifiers=["com.fixture.app"]
    var rules:[Target]=[];var directories:[Target]=[]
}
struct Decoded { let project:PatchProject }
struct Summary { let packageID:UUID }
enum PatchPackageCodec {
    @MainActor static func decode(_ data:Data,password:String?)throws->Decoded { Decoded(project:Fixture.nextProject) }
    @MainActor static func inspect(_ data:Data)throws->Summary { Summary(packageID:Fixture.nextProject.id) }
}
enum AppSecurityConfiguration { static func protectedBundleID(forVariant:String)->String? { "com.fixture.app" } }
enum AppInfo { static let versionTuple=(26,6,2),osBuild="fixture" }
enum ExploitSupportPolicy { enum Mode { case direct,airLift,unsupported }; static let currentStorageMode:Mode = .direct }
enum WorseQueryHelper { static let isOSSupported=true,isAvailable=true }
func log(_ text:String) {}
@MainActor final class AuthManager {
    enum State { case idle,verified }
    var authState:State = .verified;var authenticationRevision:UInt64=1
}
@MainActor final class NetworkAccessGate {
    static let shared=NetworkAccessGate()
    func requireAllowed()async throws->Int { try Task.checkCancellation();return 1 }
    func validateGeneration(_ value:Int)throws { try Task.checkCancellation() }
}
@MainActor final class AppIntegrityRuntime { static let shared=AppIntegrityRuntime();func requireAllowed(force:Bool)async throws {} }
enum IntegrityCommitBarrier { static func withCommit<T>(_ operation:()throws->T)rethrows->T { try operation() } }
enum DirectPatchExecutor {
    @MainActor static func run<T>(validation: @escaping @MainActor ()throws->Void,
                                  operation:()throws->T)async throws->T {
        try validation();return try operation()
    }
}
@MainActor enum Fixture {
    static let root=FileManager.default.temporaryDirectory.appendingPathComponent("catalog-recovery-"+UUID().uuidString)
    static let defaults=UserDefaults(suiteName:"catalog-recovery-"+UUID().uuidString)!
    static var store:PatchEngineApplicationStore { PatchEngineApplicationStore(backupRoot:root) }
    static var states:[UUID:PatchApplicationState]=[:], receipts:[UUID:PatchTransactionReceipt]=[:]
    static var downloads=0,applies=0,restores=0
    static var failApply=false,partialApply=false,changed=false,forcedRestore=false
    static var snapshot=Data([1,2,3]),nextProject=PatchProject()
    static func reset()throws {
        try? FileManager.default.removeItem(at:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey:key) }
        states=[:];receipts=[:];downloads=0;applies=0;restores=0
        failApply=false;partialApply=false;changed=false;forcedRestore=false
        snapshot=Data([1,2,3]);nextProject=PatchProject()
    }
    static func establish(_ projectID:UUID, state:PatchApplicationState = .applied)throws {
        let receipt=PatchTransactionReceipt(id:UUID(),projectID:projectID,
            journalURL:root.appendingPathComponent(projectID.uuidString).appendingPathComponent("journal.plist"))
        receipts[projectID]=receipt;states[projectID]=state
        try FileManager.default.createDirectory(at:receipt.journalURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("journal-fixture".utf8).write(to:receipt.journalURL)
        try store.save(PatchEngineApplicationRecord(projectID:projectID,engine:.worseQuery,
            baseline:.capturedPriorState,targetKeys:["com.fixture.app\0Documents/file"],journalID:receipt.id,
            phase:state == .applied ? .applied:.recoveryRequired))
    }
}
@MainActor enum PatchProjectLibrary { static func backupRootURL()throws->URL { Fixture.root } }
@MainActor enum DevicePatchService {
    static func latestReceipt(projectID:UUID)->PatchTransactionReceipt? { Fixture.receipts[projectID] }
    static func recordedApplicationState(projectID:UUID)->PatchApplicationState? { Fixture.states[projectID] }
    static func prepareContainers(bundleIDs:[String])async throws->[String:URL] { [:] }
    static func prepareContainers(receipt:PatchTransactionReceipt)async throws->[String:URL] { [:] }
    static func inspectExistingApplication(receipt:PatchTransactionReceipt,project:PatchProject,
                                           preparedContainers:[String:URL]?)throws->PatchApplicationState { Fixture.states[project.id] ?? .off }
    static func inspectRestore(receipt:PatchTransactionReceipt,preparedContainers:[String:URL]?)throws->PatchRestoreInspection {
        PatchRestoreInspection(changedTargets:Fixture.changed ? [PatchTargetChange(bundleID:"com.fixture.app",relativePath:"Documents/file",kind:.modified)]:[],currentStateSnapshot:Fixture.snapshot)
    }
    static func apply(project:PatchProject,preparedContainers:[String:URL]?)throws {
        Fixture.applies += 1
        if Fixture.failApply { throw CatalogCheckError.writeFailure }
        try Fixture.establish(project.id,state:Fixture.partialApply ? .recoveryRequired:.applied)
        if Fixture.partialApply { throw CatalogCheckError.writeFailure }
    }
    static func restore(receipt:PatchTransactionReceipt,allowChangedTargets:Bool,
                        expectedCurrentState:Data?,preparedContainers:[String:URL])throws {
        if let expectedCurrentState,expectedCurrentState != Fixture.snapshot {
            throw PatchPackageError.restoreTargetsChanged(["com.fixture.app/Documents/file"])
        }
        if Fixture.changed && !allowChangedTargets { throw PatchPackageError.restoreTargetsChanged(["com.fixture.app/Documents/file"]) }
        Fixture.restores += 1;Fixture.forcedRestore=allowChangedTargets;Fixture.states[receipt.projectID] = .off
    }
}
@MainActor final class StorageEngineCoordinator {
    static let shared=StorageEngineCoordinator();let isAirLiftActive=false
    func applicationStore()throws->PatchEngineApplicationStore { Fixture.store }
    func projectApplicationState(_ id:UUID)->PatchApplicationState? {
        do { return PatchEngineApplicationStore.reconcile(record:try Fixture.store.read(id),journal:Fixture.states[id],legacyAirLift:false) }
        catch { return .recoveryRequired }
    }
    func applyPatchProjectInOperation(_ project:PatchProject,operationID:UUID)async throws { throw CatalogCheckError.writeFailure }
}
