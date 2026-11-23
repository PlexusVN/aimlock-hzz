import Foundation

enum PatchApplicationState: String, Sendable { case off, applied, recoveryRequired
    var requiresRestore: Bool { self != .off }
}
enum PatchEngineStateError: Error { case invalidRecord }
struct FixtureRecord { var state: PatchApplicationState; let journalID: UUID?; let operationID: UUID }
enum Disk {
    static let lock = NSLock()
    static var records: [UUID: FixtureRecord] = [:]
    static var reads = 0
    static var blockNext = false, blocked = false
    static var blockID: UUID?
    static let release = DispatchSemaphore(value: 0)
    static func read(_ id: UUID) -> FixtureRecord? {
        lock.lock(); reads += 1; let value = records[id], pause = blockNext || blockID == id
        blockNext = false; if pause { blocked = true; blockID = nil }; lock.unlock()
        if pause { release.wait() }
        return value
    }
    static var didBlock: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
}
struct PatchEngineApplicationStore {
    let backupRoot: URL
    func read(_ id: UUID) throws -> FixtureRecord? { Disk.read(id) }
    static func reconcile(record: FixtureRecord?, journal: PatchApplicationState?, legacyAirLift: Bool) -> PatchApplicationState? {
        record?.state ?? journal ?? (legacyAirLift ? .recoveryRequired : nil)
    }
}
enum PatchTransaction {
    struct Receipt { let id: UUID }
    static func latestRecordedApplicationState(projectID: UUID, backupRoot: URL) -> PatchApplicationState? { nil }
    static func latestReceipt(projectID: UUID, backupRoot: URL) -> Receipt? { nil }
}
struct PatchItem { let id: Int; let slug: String; var artifactVariant: String? = "generic"
    var downloadIdentity: String { "\(id):\(artifactVariant ?? "legacy")" }
}
enum PatchProjectLibrary { static var root = FileManager.default.temporaryDirectory
    static func backupRootURL() throws -> URL { root }
}
// PRESENTATION_TYPES

@MainActor final class PresentationService {
    var cardPresentations: [String: CatalogFeaturePresentation] = [:]
    var presentationReady = false, patchOperationInProgress = false
    var presentationGeneration: UInt64 = 0
    var presentationRefreshTask: Task<Void, Never>?
    var patches: [PatchItem] = []
    var requestedProjectOverrides: [UUID: Bool] = [:], requestedProjectBindings: [UUID: String] = [:]
    var requestedStateOverrides: [String: Bool] = [:], requestedStateBindings: [String: String] = [:]
    var recoveryItems: [PatchRecoveryItem] = [], recoveryInventoryError: String?
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func refresh() { requestPresentationRefresh() }
    func displayIntent(_ enabled:Bool, identity:String) { updateDisplayedIntent(enabled, identity:identity) }
    func beginOperation() { suspendPresentationRefresh(); patchOperationInProgress = true }
    func wait() async { await presentationRefreshTask?.value }
    // PRESENTATION_METHODS
}

@main struct CatalogPresentationSelfCheck {
    @MainActor static func main() async throws {
        let suite = "presentation-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        PatchProjectLibrary.root = root
        let id = UUID(), journal = UUID(), key = "catalog_1_generic"
        let binding = id.uuidString + ":journal:" + journal.uuidString
        Disk.records[id] = FixtureRecord(state: .applied, journalID: journal, operationID: UUID())
        defaults.set(id.uuidString, forKey: "patch_applied_" + key + "_projectID")
        defaults.set(id.uuidString, forKey: "patch_applied_catalog_2_generic_projectID")
        let targets = [CatalogPresentationTarget(key: "1:generic", identity: key, legacyIdentity: "old_generic"),
                       CatalogPresentationTarget(key: "2:generic", identity: "catalog_2_generic", legacyIdentity: "other_generic")]
        var snapshot = try CatalogPresentationReader.load(root: root, defaults: defaults, targets: targets, overrides: .init())
        precondition(snapshot.cards.values.allSatisfy(\.enabled) && Disk.reads == 1, "read each project only once per snapshot")
        defaults.set(false, forKey: "patch_requested_project_" + id.uuidString)
        defaults.set(binding, forKey: "patch_requested_project_binding_" + id.uuidString)
        snapshot = try CatalogPresentationReader.load(root: root, defaults: defaults, targets: targets, overrides: .init())
        precondition(snapshot.cards.values.allSatisfy { !$0.enabled }, "bound OFF intent must survive refresh")
        defaults.set("older-journal", forKey: "patch_requested_project_binding_" + id.uuidString)
        snapshot = try CatalogPresentationReader.load(root: root, defaults: defaults, targets: targets, overrides: .init())
        precondition(snapshot.cards.values.allSatisfy(\.enabled), "stale OFF intent must not attach to a new transaction")
        defaults.set(binding, forKey: "patch_requested_project_binding_" + id.uuidString)
        let overrides = CatalogPresentationOverrides(projectValues: [id: true], projectBindings: [id: binding])
        snapshot = try CatalogPresentationReader.load(root: root, defaults: defaults, targets: targets, overrides: overrides)
        precondition(snapshot.cards.values.allSatisfy(\.enabled), "current in-memory intent wins")
        defaults.set(true, forKey: "patch_requested_project_" + id.uuidString)
        let service = PresentationService(defaults)
        service.patches = [PatchItem(id: 1, slug: "old"), PatchItem(id: 2, slug: "other")]
        let before = Disk.reads
        for _ in 0..<20 { service.refresh() }
        await service.wait()
        precondition(service.presentationReady && Disk.reads == before + 1, "refresh bursts must coalesce")
        for _ in 0..<10_000 { precondition(service.presentation(for: service.patches[0]).enabled) }
        precondition(Disk.reads == before + 1, "rendering must perform zero journal reads")
        service.displayIntent(false, identity:key)
        precondition(!service.presentation(for:service.patches[0]).enabled && Disk.reads == before + 1,
            "OFF intent must be visible immediately without disk reads")
        service.displayIntent(true, identity:key)
        let orphan = UUID()
        defaults.set(orphan.uuidString, forKey: "patch_applied_unassociated_projectID")
        Disk.blocked = false; Disk.blockID = orphan
        service.presentationReady = false; service.refresh()
        for _ in 0..<1000 { if Disk.didBlock { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(Disk.didBlock)
        for _ in 0..<1000 { if service.presentationReady { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(service.presentationReady, "switches must not wait for old history to finish scanning")
        Disk.release.signal(); await service.wait()
        let afterEarlyCards = Disk.reads
        service.beginOperation()
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(!service.presentationReady && Disk.reads == afterEarlyCards, "do not scan during a write")
        service.patchOperationInProgress = false
        Disk.blocked = false; Disk.blockNext = true; service.refresh()
        let stale = service.presentationRefreshTask
        for _ in 0..<1000 { if Disk.didBlock { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(Disk.didBlock)
        defaults.set(false, forKey: "patch_requested_project_" + id.uuidString)
        service.refresh(); await service.wait()
        precondition(!service.presentation(for: service.patches[0]).enabled)
        Disk.release.signal(); await stale?.value
        precondition(!service.presentation(for: service.patches[0]).enabled, "late disk results must not restore an old switch state")
        defaults.set("invalid UUID", forKey: "patch_applied_" + key + "_projectID")
        defaults.set(id.uuidString, forKey: "patch_applied_old_generic_projectID")
        snapshot = try CatalogPresentationReader.load(root: root, defaults: defaults, targets: targets, overrides: .init())
        precondition(snapshot.cards["1:generic"]?.state == .applied, "legacy association remains readable")
        print("[PASS] catalog presentation: deduplicated reads, bound intent, 10,000 memory-only renders, coalescing and stale-result rejection")
    }
}
