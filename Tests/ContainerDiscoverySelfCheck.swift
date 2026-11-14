import Foundation
import Darwin

enum PatchPackageError: Error { case invalidBundleIdentifier; case targetAppUnavailable(String) }
enum AppInfo {
    static let osBuild = "24A-fixture"
    static var versionTuple: (major: Int, minor: Int, patch: Int) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion, v.patchVersion)
    }
}
enum ProcessInfo {
    static var processInfo = FixtureProcessInfo()
    struct FixtureProcessInfo { var operatingSystemVersion = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1) }
}
final class FileManager {
    static let `default` = FileManager()
    var temporaryDirectory: URL { Foundation.FileManager.default.temporaryDirectory }
    func contentsOfDirectory(atPath path: String) throws -> [String] {
        precondition(DiscoveryFixture.active.values.contains(path), "directory read without this UUID grant")
        if DiscoveryFixture.readDenied { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        if DiscoveryFixture.replaceGame && path == DiscoveryFixture.game { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        return []
    }
    func urls(for directory: Foundation.FileManager.SearchPathDirectory, in domain: Foundation.FileManager.SearchPathDomainMask) -> [URL] {
        Foundation.FileManager.default.urls(for: directory, in: domain)
    }
    func removeItem(at url: URL) throws { try Foundation.FileManager.default.removeItem(at: url) }
    func createDirectory(at url: URL, withIntermediateDirectories value: Bool) throws {
        try Foundation.FileManager.default.createDirectory(at: url, withIntermediateDirectories: value)
    }
}

enum UserDefaults {
    static let suite = "astra-ios27-fixture-" + UUID().uuidString
    static let standard = Foundation.UserDefaults(suiteName: suite)!
}
enum DiscoveryFixture {
    static let gameID = "com.fixture.first", maxID = "com.fixture.second"
    static let game = "/private/var/mobile/Containers/Data/Application/CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    static let max = "/private/var/mobile/Containers/Data/Application/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    static let replacementGame = "/private/var/mobile/Containers/Data/Application/DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    static let other = "/private/var/mobile/Containers/Data/Application/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    static let progress = ContainerScanProgress(historyURL: nil)
    static var ranges: [(UInt64, UInt64)] = []
    static var active: [Int64: String] = [:]
    static var next: Int64 = 1
    static var calls = 0, legacyCalls = 0
    static var reject = false, noMatch = false, setupError = false, missingGroup = false, cancel = false
    static var ranOnMain = false
    static var preflightFailed = false, localLinkFailed = false, readDenied = false
    static var onlyFirst = false, duplicateFirst = false, noCandidates = false, replaceGame = false, identityReads = 0
    static func reset(clearCache: Bool = true) {
        ranges = []; active = [:]; next = 1; calls = 0; legacyCalls = 0
        reject = false; noMatch = false; setupError = false; missingGroup = false; cancel = false; ranOnMain = false
        preflightFailed = false; localLinkFailed = false; readDenied = false; onlyFirst = false; duplicateFirst = false; noCandidates = false; replaceGame = false; identityReads = 0
        if clearCache { UserDefaults.standard.removePersistentDomain(forName: UserDefaults.suite) }
        IOS27ContainerSession.reset()
    }
}
enum WorseQueryHelper {
    static let preparationContext = "fixture signed groups"
    static let nativeDiagnostics = "stage=create_Caches_symlink domain=NSPOSIXErrorDomain code=13"
    static func preparationDiagnostics() throws -> String {
        precondition(!Thread.isMainThread)
        if DiscoveryFixture.preflightFailed { throw WorseQueryError.localFilesystemFailure("preflight denied: NSPOSIXErrorDomain code=13") }
        return "preflight passed"
    }
    static func invalidateActiveAppGroup() {}
    static func resolveActiveAppGroup() -> String? { "group.fixture" }
    static let isOSSupported = true
    static var isAppGroupConfigured: Bool { !DiscoveryFixture.missingGroup }
    static let isAvailable = true
    static func currentFilesystemMaxInode() throws -> UInt64 { 2_100_000 }
    static func enumeratePaths(in path: String, from first: UInt64, through last: UInt64) throws -> [String] {
        DiscoveryFixture.ranOnMain = DiscoveryFixture.ranOnMain || Thread.isMainThread
        if DiscoveryFixture.setupError { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        DiscoveryFixture.ranges.append((first, last))
        if DiscoveryFixture.noCandidates { return [] }
        if DiscoveryFixture.cancel { DiscoveryFixture.progress.requestCancellation() }
        var paths: [String] = []
        for (inode, path) in [(UInt64(20), DiscoveryFixture.other), (DiscoveryFixture.duplicateFirst ? 25 : 2_000_000, DiscoveryFixture.game), (2_050_000, DiscoveryFixture.max)] {
            if DiscoveryFixture.onlyFirst && path == DiscoveryFixture.max { continue }
            if first <= inode && last >= inode {
                paths.append(DiscoveryFixture.replaceGame && path == DiscoveryFixture.game ? DiscoveryFixture.replacementGame : path)
            }
        }
        return paths
    }
    static func acquireAccess(for path: String) throws -> Int64 {
        precondition(!Thread.isMainThread, "native query executed on main thread")
        DiscoveryFixture.calls += 1
        if DiscoveryFixture.localLinkFailed { throw WorseQueryError.localFilesystemFailure(nativeDiagnostics) }
        if DiscoveryFixture.reject { throw WorseQueryError.queryRejected }
        let handle = DiscoveryFixture.next; DiscoveryFixture.next += 1
        DiscoveryFixture.active[handle] = path
        return handle
    }
    static func releaseAccess(handle: Int64) { DiscoveryFixture.active.removeValue(forKey: handle) }
}
func getxattr(_ path: String, _ name: String, _ value: UnsafeMutableRawPointer?, _ size: Int, _ position: UInt32, _ options: Int32) -> Int {
    precondition(DiscoveryFixture.active.values.contains(path), "read identifier before consuming this UUID's token")
    DiscoveryFixture.identityReads += 1
    let identifier = DiscoveryFixture.noMatch ? "com.fixture.other" : (DiscoveryFixture.duplicateFirst && path == DiscoveryFixture.other) ? DiscoveryFixture.gameID : (path == DiscoveryFixture.game || path == DiscoveryFixture.replacementGame) ? DiscoveryFixture.gameID : path == DiscoveryFixture.max ? DiscoveryFixture.maxID : "com.fixture.other"
    let bytes = Array(identifier.utf8) + [0]
    if value == nil { return bytes.count - 1 }
    precondition(bytes.count - 1 <= size)
    Array(bytes.dropLast()).withUnsafeBytes { value!.copyMemory(from: $0.baseAddress!, byteCount: bytes.count - 1) }
    return bytes.count - 1
}
func log(_ line: String) {}
final class RestartFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@main struct ContainerDiscoverySelfCheck {
    @MainActor static func drain() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
    @MainActor static func targetScan(_ targets: [String], force: Bool = false) async throws -> [String: String] {
        try await Task.detached { try ContainerStore.prepareIOS27Access(bundleIDs: targets, forceScan: force) }.value
    }
    @MainActor static func main() async throws {
        for (major,minor,patch) in [(26,6,2),(26,7,0),(26,7,2),(27,0,1)] {
            ProcessInfo.processInfo.operatingSystemVersion = OperatingSystemVersion(majorVersion:major,minorVersion:minor,patchVersion:patch)
            DiscoveryFixture.reset()
            try await checkVersion()
        }
    }
    @MainActor static func checkVersion() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: UserDefaults.suite); IOS27ContainerSession.reset() }
        let preparation = IOS27ContainerPreparation(progress: DiscoveryFixture.progress,
            operation: { try ContainerStore.prepareIOS27Access(bundleIDs: $0, forceScan: $1) },
            generalOperation: { try ContainerStore.prepareWorseQueryFilesystemAccess(forceScan: $0) })
        preparation.configureTargets(bundleIDs: [DiscoveryFixture.gameID, DiscoveryFixture.maxID])
        precondition(preparation.state == .idle && !preparation.didContinue)
        preparation.enterApplication()
        precondition(!preparation.didContinue, "gate allowed entry before preparation")
        await preparation.prepareIfNeeded()
        await drain()
        precondition(preparation.state == .ready && !preparation.didContinue)
        precondition(!DiscoveryFixture.ranOnMain && DiscoveryFixture.legacyCalls == 0)
        precondition(DiscoveryFixture.ranges.first!.0 == 1 && DiscoveryFixture.ranges.last!.1 == 2_100_000)
        for index in 1..<DiscoveryFixture.ranges.count { precondition(DiscoveryFixture.ranges[index].0 == DiscoveryFixture.ranges[index - 1].1 + 1) }
        precondition(DiscoveryFixture.active.isEmpty && DiscoveryFixture.identityReads == 0,
                     "general preparation must not require app/game identity metadata")
        precondition(DiscoveryFixture.calls == 3 && DiscoveryFixture.progress.snapshot.readable == 3,
                     "general scan must inspect every candidate through the full finite window")
        preparation.enterApplication()
        precondition(preparation.didContinue)
        precondition(IOS27ContainerSession.path(for: DiscoveryFixture.maxID) == nil,
                     "initial gate unnecessarily scanned for every optional app")
        let generalRangeCount = DiscoveryFixture.ranges.count
        let generalGrantCount = DiscoveryFixture.calls
        try await preparation.prepareAdditionalTargets(bundleIDs: [DiscoveryFixture.gameID, DiscoveryFixture.maxID])
        precondition(DiscoveryFixture.ranges.count == generalRangeCount,
                     "the first actual patch repeated a completed inode scan instead of revalidating candidate hints")
        precondition(DiscoveryFixture.calls > generalGrantCount && DiscoveryFixture.identityReads > 0 && DiscoveryFixture.active.isEmpty,
                     "candidate reuse bypassed fresh per-UUID grants or identity verification")
        precondition(IOS27ContainerSession.path(for: DiscoveryFixture.gameID) == DiscoveryFixture.game && DiscoveryFixture.legacyCalls == 0)
        precondition(IOS27ContainerSession.path(for: DiscoveryFixture.maxID) == DiscoveryFixture.max,
                     "cached first target short-circuited the installed second target")

        preparation.reset(); DiscoveryFixture.reset(clearCache: false)
        _ = try await targetScan([DiscoveryFixture.gameID, DiscoveryFixture.maxID], force: true); await drain()
        precondition(DiscoveryFixture.ranges.isEmpty)
        precondition(DiscoveryFixture.calls == 2, "cache bypassed real token/identifier verification")

        preparation.reset(); DiscoveryFixture.reset(clearCache: false)
        UserDefaults.standard.removeObject(forKey: "astra.resolved_container.\(DiscoveryFixture.maxID)")
        _ = try await targetScan([DiscoveryFixture.gameID, DiscoveryFixture.maxID]); await drain()
        precondition(DiscoveryFixture.ranges.isEmpty && DiscoveryFixture.calls == 3,
                     "lazy target hints failed fresh identity validation/dedup or repeated enumeration")
        preparation.reset(forceScan: true); DiscoveryFixture.reset(clearCache: false)
        UserDefaults.standard.removeObject(forKey: "astra.resolved_container.\(DiscoveryFixture.maxID)")
        let rescanned = try await targetScan([DiscoveryFixture.gameID, DiscoveryFixture.maxID], force: true); await drain()
        precondition(!DiscoveryFixture.ranges.isEmpty && rescanned[DiscoveryFixture.maxID] != nil,
                     "explicit lazy target rescan could not discover a newly installed variant")

        // An installed app can acquire a different UUID after the general
        // scan. Stale hints are candidates only; unreadable/absent paths cannot
        // suppress the fallback scan or become a bundle mapping.
        preparation.reset(); DiscoveryFixture.reset()
        await preparation.prepareIfNeeded(force: true); await drain()
        preparation.enterApplication()
        DiscoveryFixture.replaceGame = true
        let beforeFallbackRanges = DiscoveryFixture.ranges.count
        try await preparation.prepareAdditionalTargets(bundleIDs: [DiscoveryFixture.gameID])
        precondition(DiscoveryFixture.ranges.count > beforeFallbackRanges,
                     "missing/stale candidate hints suppressed the lazy fallback inode scan")
        precondition(IOS27ContainerSession.path(for: DiscoveryFixture.gameID) == DiscoveryFixture.replacementGame,
                     "stale hinted UUID was used instead of the fresh identified target")

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.onlyFirst = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .ready && IOS27ContainerSession.path(for: DiscoveryFixture.gameID) == nil,
                     "general readiness published an unverified game target")
        precondition(IOS27ContainerSession.path(for: DiscoveryFixture.maxID) == nil)
        preparation.enterApplication()
        try await preparation.prepareAdditionalTargets(bundleIDs: [DiscoveryFixture.gameID])
        do {
            try await preparation.prepareAdditionalTargets(bundleIDs: [DiscoveryFixture.maxID])
            preconditionFailure("missing requested application became prepared")
        } catch WorseQueryError.containerDiscoveryFailed {}
        precondition(preparation.didContinue && IOS27ContainerSession.path(for: DiscoveryFixture.gameID) != nil,
                     "failed additional target erased the already verified session")

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.missingGroup = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .failed && !preparation.didContinue)
        preparation.enterApplication(); precondition(!preparation.didContinue)
        precondition(DiscoveryFixture.calls == 0 && DiscoveryFixture.ranges.isEmpty)

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.preflightFailed = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .failed && !preparation.didContinue)
        precondition(DiscoveryFixture.calls == 0 && DiscoveryFixture.ranges.isEmpty,
                     "failed local write probe still scanned the entire filesystem")
        precondition(DiscoveryFixture.progress.shareText.contains("NSPOSIXErrorDomain code=13"))

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.localLinkFailed = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .failed && !preparation.didContinue)
        precondition(DiscoveryFixture.calls == 1 && DiscoveryFixture.ranges.count == 1,
                     "global Caches failure retried on every unrelated container")
        precondition(DiscoveryFixture.progress.snapshot.candidates == 1 && DiscoveryFixture.progress.snapshot.grants == 0)
        precondition(DiscoveryFixture.progress.shareText.contains("stage=create_Caches_symlink"))

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.reject = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .failed && IOS27ContainerSession.path(for: DiscoveryFixture.gameID) == nil)
        precondition(DiscoveryFixture.progress.snapshot.detail.contains("query"))

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.noMatch = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .ready && DiscoveryFixture.ranges.last!.1 == 2_100_000,
                     "no installed game must not block general filesystem readiness")
        precondition(DiscoveryFixture.identityReads == 0)
        preparation.enterApplication()
        do {
            try await preparation.prepareAdditionalTargets(bundleIDs: [DiscoveryFixture.gameID])
            preconditionFailure("missing requested game must not become a verified patch target")
        } catch WorseQueryError.containerDiscoveryFailed {}
        precondition(preparation.didContinue && IOS27ContainerSession.path(for: DiscoveryFixture.gameID) == nil)

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.noCandidates = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .failed && DiscoveryFixture.calls == 0 && DiscoveryFixture.ranges.last!.1 == 2_100_000,
                     "no readable candidate is not proof of general access")

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.readDenied = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .failed && DiscoveryFixture.progress.snapshot.grants == 3)
        precondition(DiscoveryFixture.progress.snapshot.readable == 0 && DiscoveryFixture.progress.snapshot.identified == 0)
        precondition(IOS27ContainerSession.path(for: DiscoveryFixture.gameID) == nil)

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.duplicateFirst = true
        preparation.configureTargets(bundleIDs: [DiscoveryFixture.gameID])
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .ready && IOS27ContainerSession.path(for: DiscoveryFixture.gameID) == nil,
                     "general scan must not assign any game UUID")
        preparation.enterApplication()
        do {
            try await preparation.prepareAdditionalTargets(bundleIDs: [DiscoveryFixture.gameID])
            preconditionFailure("duplicate target identifiers selected an arbitrary UUID")
        } catch WorseQueryError.containerDiscoveryFailed {}
        precondition(DiscoveryFixture.progress.shareText.contains("nhiều UUID"))
        preparation.configureTargets(bundleIDs: [DiscoveryFixture.gameID, DiscoveryFixture.maxID])

        preparation.reset(); DiscoveryFixture.reset(); DiscoveryFixture.cancel = true
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .failed && !preparation.didContinue && DiscoveryFixture.active.isEmpty)
        precondition(DiscoveryFixture.progress.snapshot.phase == .cancelled)
        do { _ = try ContainerStore.resolveAppContainerForPatch(bundleID: DiscoveryFixture.gameID); preconditionFailure("patch bypassed preparation") }
        catch WorseQueryError.preparationRequired {}
        precondition(DiscoveryFixture.legacyCalls == 0)
        DiscoveryFixture.cancel = false
        let cancelledRangeCount = DiscoveryFixture.ranges.count
        _ = try await targetScan([DiscoveryFixture.gameID])
        precondition(DiscoveryFixture.ranges.count > cancelledRangeCount,
                     "a cancelled general scan retained/published candidate hints")
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("astra-gate-interrupted-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: history) }
        let previous = ContainerScanSnapshot(id: UUID(), bundleID: DiscoveryFixture.gameID, phase: .scanning)
        try JSONEncoder().encode(previous).write(to: history)
        let interruptedProgress = ContainerScanProgress(historyURL: history)
        let restarted = RestartFlag()
        let interruptedGate = IOS27ContainerPreparation(progress: interruptedProgress,
            operation: { _, _ in preconditionFailure("initial readiness must not resolve game targets") },
            generalOperation: { _ in restarted.set() })
        interruptedGate.configureTargets(bundleIDs: [DiscoveryFixture.gameID])
        await interruptedGate.prepareIfNeeded()
        precondition(interruptedGate.state == .failed && !restarted.value && !interruptedGate.didContinue)
        await interruptedGate.prepareIfNeeded(force: true)
        precondition(interruptedGate.state == .ready && restarted.value && !interruptedGate.didContinue)
        preparation.reset(); DiscoveryFixture.reset()
        preparation.configureTargets(bundleIDs: [])
        await preparation.prepareIfNeeded(force: true); await drain()
        precondition(preparation.state == .ready && DiscoveryFixture.ranges.last!.1 == 2_100_000,
                     "general readiness must accept an empty game capability list")
        print("[PASS] actual general readiness and lazy target preparation: \(AppInfo.versionTuple.major).\(AppInfo.versionTuple.minor).\(AppInfo.versionTuple.patch), high inodes, both games, cache revalidation, no legacy MCM/LS, per-UUID tokens, off-main, missing group, failure/cancel blocks entry and patch")
    }
}
