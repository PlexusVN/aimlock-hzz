// Only external transport/OS boundaries are fixtures. The runner extracts the
// unchanged production catalog methods, registry, gate and provenance store.
enum CatalogCheckError: Error { case failed(String), writeFailure }
enum FeaturePatchError: Error { case notAuthenticated, operationInProgress }
enum ProtectedDownloadError: Error { case invalidResponse }
enum WorseQueryError: Error { case unsupportedOS(String) }
enum PatchPackageError: Error { case restoreTargetsChanged([String]), symbolicLinkUnsupported, invalidBundleIdentifier, unsafeTargetPath }
enum PatchOperationStage: String { case download, decode, target, access, write }
struct PatchOperationError: Error {
    let stage: PatchOperationStage
    let underlying: Error
    static func wrap(_ error: Error, at: PatchOperationStage) -> Self { Self(stage:at,underlying:error) }
}
struct PatchItem {
    let id:Int; let name:String; let slug:String; var artifactVariant:String?="ffth"
    var downloadIdentity:String { "\(id):\(artifactVariant ?? "legacy")" }
}
// Production project models are included by the runner. This convenience
// initializer only supplies a valid application package for recovery scenarios.
extension PatchProject {
    init() {
        self.init(name:"Fixture", bundleIdentifiers:["com.dts.freefireth"],
                  rules:[PatchRule(bundleID:"com.dts.freefireth",relativePath:"Documents/file",
                                   replacementFilename:"file",replacementData:Data([1]))])
    }
}
struct Decoded { let project:PatchProject }
struct Summary { let packageID:UUID }
enum PatchPackageCodec {
    static func decode(_ data:Data,password:String?)throws->Decoded { Decoded(project:try JSONDecoder().decode(PatchProject.self,from:data)) }
    @MainActor static func inspect(_ data:Data)throws->Summary { Summary(packageID:Fixture.nextProject.id) }
}
enum AppSecurityConfiguration {
    static func protectedBundleID(forVariant variant:String)->String? {
        switch variant {
        case "ffth":return "com.dts.freefireth"
        case "ffmax":return "com.dts.freefiremax"
        case "capcut":return "com.lemon.lvoverseas"
        default:return nil
        }
    }
    static func supportsProtectedArtifact(variant:String,kind:String)->Bool {
        switch kind {
        case "package":return ["ffth","ffmax","capcut","generic"].contains(variant)
        case "mod","original":return ["ffth","ffmax"].contains(variant)
        default:return false
        }
    }
}
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
    static var downloads=0,prepares=0,applies=0,restores=0
    static var preparedBundleIDs:[String]=[]
    static var failApply=false,partialApply=false,changed=false,forcedRestore=false,failRestore=false,failInspect=false
    static var snapshot=Data([1,2,3]),nextProject=PatchProject()
    static func reset()throws {
        try? FileManager.default.removeItem(at:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey:key) }
        states=[:];receipts=[:];downloads=0;prepares=0;applies=0;restores=0;preparedBundleIDs=[]
        failApply=false;partialApply=false;changed=false;forcedRestore=false;failRestore=false;failInspect=false
        snapshot=Data([1,2,3]);nextProject=PatchProject()
    }
    static func establish(_ projectID:UUID, state:PatchApplicationState = .applied)throws {
        if let previous=receipts[projectID],
           let data=try? Data(contentsOf:previous.journalURL),
           var journal=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any] {
            journal["status"]="restored"
            try PropertyListSerialization.data(fromPropertyList:journal,format:.binary,options:0)
                .write(to:previous.journalURL,options:.atomic)
        }
        let transactionID=UUID()
        let receipt=PatchTransactionReceipt(id:transactionID,projectID:projectID,
            journalURL:root.appendingPathComponent(projectID.uuidString).appendingPathComponent(transactionID.uuidString)
                .appendingPathComponent("journal.plist"))
        receipts[projectID]=receipt;states[projectID]=state
        try FileManager.default.createDirectory(at:receipt.journalURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let journal:[String:Any]=["schemaVersion":2,"transactionID":transactionID.uuidString,"projectID":projectID.uuidString,
            "createdAt":Date(),"status":state == .applied ? "applied":"prepared",
            "records":[["bundleID":"com.dts.freefireth","relativePath":"Documents/file","containerFingerprint":Data(repeating:7,count:32)]],
            "createdDirectories":[]]
        try PropertyListSerialization.data(fromPropertyList:journal,format:.binary,options:0).write(to:receipt.journalURL,options:.atomic)
        try store.save(PatchEngineApplicationRecord(projectID:projectID,operationID:transactionID,engine:.worseQuery,
            baseline:.capturedPriorState,targetKeys:["com.dts.freefireth\0Documents/file"],journalID:transactionID,
            phase:state == .applied ? .applied:.recoveryRequired))
    }
}
@MainActor enum PatchProjectLibrary { static func backupRootURL()throws->URL { Fixture.root } }
@MainActor enum DevicePatchService {
    static func latestReceipt(projectID:UUID)->PatchTransactionReceipt? {
        Fixture.states[projectID] == .off ? nil : Fixture.receipts[projectID]
    }
    static func recordedApplicationState(projectID:UUID)->PatchApplicationState? { Fixture.states[projectID] }
    static func prepareContainers(bundleIDs:[String])async throws->[String:URL] { Fixture.prepares += 1;Fixture.preparedBundleIDs=bundleIDs;return [:] }
    static func prepareContainers(receipt:PatchTransactionReceipt)async throws->[String:URL] { [:] }
    static func inspectExistingApplication(receipt:PatchTransactionReceipt,project:PatchProject,
                                           preparedContainers:[String:URL]?)throws->PatchApplicationState {
        Fixture.changed ? .recoveryRequired : Fixture.states[project.id] ?? .off
    }
    static func inspectRestore(receipt:PatchTransactionReceipt,preparedContainers:[String:URL]?)throws->PatchRestoreInspection {
        if Fixture.failInspect { throw CatalogCheckError.writeFailure }
        return PatchRestoreInspection(changedTargets:Fixture.changed ? [PatchTargetChange(bundleID:"com.dts.freefireth",relativePath:"Documents/file",kind:.modified)]:[],currentStateSnapshot:Fixture.snapshot)
    }
    static func apply(project:PatchProject,preparedContainers:[String:URL]?,allowOverlappingTargets:Bool = false)throws {
        Fixture.applies += 1
        if Fixture.failApply { throw CatalogCheckError.writeFailure }
        try Fixture.establish(project.id,state:Fixture.partialApply ? .recoveryRequired:.applied)
        if Fixture.partialApply { throw CatalogCheckError.writeFailure }
    }
    static func restore(receipt:PatchTransactionReceipt,allowChangedTargets:Bool,
                        expectedCurrentState:Data?,preparedContainers:[String:URL],preserveLaterPatches:Bool = false)throws {
        if Fixture.failRestore { throw CatalogCheckError.writeFailure }
        if let expectedCurrentState,expectedCurrentState != Fixture.snapshot {
            throw PatchPackageError.restoreTargetsChanged(["com.dts.freefireth/Documents/file"])
        }
        if Fixture.changed && !allowChangedTargets { throw PatchPackageError.restoreTargetsChanged(["com.dts.freefireth/Documents/file"]) }
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
    func applyPatchProjectInOperation(_ project:PatchProject,operationID:UUID,allowOverlappingTargets:Bool = false)async throws { throw CatalogCheckError.writeFailure }
}
