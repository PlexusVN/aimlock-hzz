import CryptoKit
import Darwin
import Foundation

/// Keep filesystem diagnostics through the P06 wrapper without exposing a path
/// or the localized NSError text, which can include private container names.
private struct PatchFilesystemFailure: LocalizedError {
    let operation: String
    let underlying: NSError
    var rollbackCompleted: Bool?

    var errorDescription: String? {
        var current: NSError? = underlying
        var posix: Int?
        for _ in 0..<8 {
            guard let error = current else { break }
            if error.domain == NSPOSIXErrorDomain { posix = error.code; break }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let reason: String
        switch posix {
        case Int(EACCES), Int(EPERM): reason = "Chưa có quyền thực hiện thao tác file này."
        case Int(ENOSPC): reason = "Không đủ dung lượng để hoàn tất thao tác file."
        case Int(EROFS): reason = "Vị trí đích đang chỉ cho phép đọc."
        case Int(ENOENT): reason = "File hoặc thư mục cần dùng không còn tồn tại."
        default: reason = "Thao tác file chưa hoàn tất."
        }
        let code = "\(underlying.domain):\(underlying.code)" + (posix.map { "; errno=\($0)" } ?? "")
        let rollback = rollbackCompleted.map { $0 ? " Đã hoàn tác giao dịch." : " Chưa xác nhận hoàn tác đầy đủ; bản sao lưu được giữ lại." } ?? ""
        return "\(reason) [\(operation); \(code)]\(rollback)"
    }
}

struct PatchTransactionReceipt: Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let journalURL: URL
}

enum PatchTargetChangeKind: Equatable, Sendable {
    case modified
    case missing
}

struct PatchTargetChange: Equatable, Sendable {
    let bundleID: String
    let relativePath: String
    let kind: PatchTargetChangeKind

    var displayPath: String {
        bundleID + "/" + relativePath
    }
}

struct PatchRestoreInspection: Equatable, Sendable {
    let changedTargets: [PatchTargetChange]
    let currentStateSnapshot: Data?

    init(changedTargets: [PatchTargetChange], currentStateSnapshot: Data? = nil) {
        self.changedTargets = changedTargets
        self.currentStateSnapshot = currentStateSnapshot
    }
}

enum PatchApplicationState: Equatable {
    case off, applied, recoveryRequired
    var requiresRestore: Bool { self != .off }
}

// BEGIN PATCH ENGINE PROVENANCE — Foundation-only state and persistence.
enum PatchWriteEngine: String, Codable { case legacy3105, worseQuery, airLift }
enum PatchEnginePhase: String, Codable { case writing, applied, recoveryRequired, restored }
enum PatchBaseline: String, Codable { case capturedPriorState, unavailable, legacyUnknown }
enum PatchEngineStateError: LocalizedError {
    case recoveryRequired, legacyAmbiguous, legacyTargetsUnknown, invalidRecord, airLiftNoBackup, unsupportedAirLiftDirectory, operationNotHeld, restoreProviderUnavailable
    var errorDescription: String? {
        switch self {
        case .recoveryRequired: return "Giao dịch trước chưa được khôi phục. Giữ nguyên bản sao lưu và xử lý trạng thái cũ trước khi ghi tiếp."
        case .legacyAmbiguous: return "Có cả lịch sử AirLift và bản sao lưu trực tiếp cũ, chưa xác định được bản sao lưu được tạo trước hay sau AirLift. Aimlock Hzz giữ nguyên dữ liệu để tránh khôi phục nhầm file đã sửa."
        case .legacyTargetsUnknown: return "Lịch sử AirLift cũ thiếu thông tin ứng dụng/đường dẫn; cần xác minh hoặc khôi phục bản gốc chính thức trước khi ghi tiếp. Aimlock Hzz giữ nguyên lịch sử và bản sao lưu."
        case .invalidRecord: return "Thông tin giao dịch không còn hợp lệ. Bản sao lưu và lịch sử được giữ nguyên để kiểm tra."
        case .airLiftNoBackup: return "Lần ghi này dùng AirLift và không có bản sao lưu file trước khi ghi. Cần bản gốc chính thức đúng phiên bản; Aimlock Hzz chưa thể xác nhận đã khôi phục."
        case .unsupportedAirLiftDirectory: return "Gói yêu cầu tạo thư mục rỗng mà AirLift chưa hỗ trợ. Chưa có dữ liệu nào được ghi."
        case .operationNotHeld: return "Thao tác ghi chưa giữ phiên giao dịch độc quyền."
        case .restoreProviderUnavailable: return "Bản sao lưu trực tiếp được giữ nguyên, nhưng cơ chế truy cập của phiên bản iOS này chưa hỗ trợ khôi phục giao dịch đó."
        }
    }
}

enum AirLiftPatchCapabilities {
    static func validate(_ project: PatchProject) throws {
        guard !project.rules.isEmpty else { throw PatchEngineStateError.unsupportedAirLiftDirectory }
        // Parent directories of payload files are created by the write path.
        // An independent/empty directory has no corresponding AirTraffic write.
        guard project.directories.allSatisfy({ directory in
            project.rules.contains { $0.bundleID == directory.bundleID && $0.relativePath.hasPrefix(directory.relativePath + "/") }
        }) else { throw PatchEngineStateError.unsupportedAirLiftDirectory }
    }
}

struct PatchEngineApplicationRecord: Codable, Equatable {
    let schema: Int
    let projectID: UUID
    let operationID: UUID
    let engine: PatchWriteEngine
    let baseline: PatchBaseline
    let targetKeys: [String]
    var journalID: UUID?
    var phase: PatchEnginePhase
    var completedBatches: Int
    let totalBatches: Int

    init(projectID: UUID, operationID: UUID = UUID(), engine: PatchWriteEngine,
         baseline: PatchBaseline, targetKeys: [String], journalID: UUID? = nil,
         phase: PatchEnginePhase = .writing, totalBatches: Int = 0) {
        schema = 1; self.projectID = projectID; self.operationID = operationID
        self.engine = engine; self.baseline = baseline; self.targetKeys = targetKeys.sorted()
        self.journalID = journalID; self.phase = phase; completedBatches = 0; self.totalBatches = totalBatches
    }
    var applicationState: PatchApplicationState {
        switch phase {
        case .writing, .recoveryRequired: return .recoveryRequired
        case .applied: return .applied
        case .restored: return .off
        }
    }
    func validate() throws {
        guard schema == 1, completedBatches >= 0, totalBatches >= completedBatches,
              !targetKeys.isEmpty, targetKeys == Array(Set(targetKeys)).sorted(),
              targetKeys.allSatisfy({ !$0.isEmpty && $0.contains("\0") }),
              (engine == .airLift ? baseline == .unavailable && journalID == nil : baseline != .unavailable && journalID != nil) else {
            throw PatchEngineStateError.invalidRecord
        }
    }
}

struct PatchEngineApplicationStore {
    let backupRoot: URL
    static let maximumRecordBytes = 2 * 1024 * 1024
    static let maximumJournalBytes = 64 * 1024 * 1024
    private var directory: URL { backupRoot.appendingPathComponent(".engine-applications", isDirectory: true) }
    private func url(_ projectID: UUID) -> URL { directory.appendingPathComponent(projectID.uuidString + ".plist") }

    // A projection of the same atomic journal, not another independently
    // written receipt. Schema 3 binds the immutable engine descriptor to the
    // backups before any target mutation. Old journals have no descriptor.
    private struct JournalProjection: Decodable {
        struct Target: Decodable {
            let bundleID: String
            let relativePath: String
            let containerFingerprint: Data
            var key: String { bundleID + "\0" + relativePath }
        }
        let schemaVersion: Int
        let transactionID: UUID
        let projectID: UUID
        let createdAt: Date
        let status: String
        let records: [Target]
        let createdDirectories: [Target]?
        let declaredDirectories: [Target]?
        let engineRecord: PatchEngineApplicationRecord?
        var isTerminal: Bool { status == "restored" || status == "rolledBack" }
    }

    static func encodedRecord(_ record: PatchEngineApplicationRecord) throws -> Data {
        try record.validate()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        guard data.count <= maximumRecordBytes else { throw PatchEngineStateError.invalidRecord }
        return data
    }

    private func readProjection(projectID: UUID, transactionID: UUID) throws -> JournalProjection {
        let path = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true).appendingPathComponent("journal.plist")
        let data = try Data(contentsOf: path)
        guard data.count <= Self.maximumJournalBytes,
              let journal = try? PropertyListDecoder().decode(JournalProjection.self, from: data),
              (1...3).contains(journal.schemaVersion), journal.projectID == projectID,
              journal.transactionID == transactionID,
              ["prepared", "applied", "restored", "rolledBack"].contains(journal.status) else {
            throw PatchEngineStateError.invalidRecord
        }
        for target in journal.records + (journal.createdDirectories ?? []) + (journal.declaredDirectories ?? []) {
            guard try PatchPathValidator.canonicalBundleIdentifier(target.bundleID) == target.bundleID,
                  try PatchPathValidator.canonicalRelativePath(target.relativePath) == target.relativePath,
                  target.containerFingerprint.count == 32 else { throw PatchEngineStateError.invalidRecord }
        }
        if let record = journal.engineRecord {
            _ = try Self.encodedRecord(record)
            guard journal.schemaVersion == 3, record.projectID == projectID,
                  record.operationID == transactionID, record.journalID == transactionID,
                  record.engine != .airLift, record.baseline == .capturedPriorState,
                  record.phase == .writing, record.completedBatches == 0, record.totalBatches == 0,
                  Set(journal.records.map(\.key)).isSubset(of: Set(record.targetKeys)),
                  journal.declaredDirectories.map({ Set($0.map(\.key)).union(journal.records.map(\.key)) == Set(record.targetKeys) }) ?? true,
                  (journal.createdDirectories ?? []).allSatisfy({ directory in
                      // Auto-created parents need not be explicit package
                      // targets, but must belong to a bound payload/directory.
                      record.targetKeys.contains { $0 == directory.key || $0.hasPrefix(directory.key + "/") }
                  }) else {
                throw PatchEngineStateError.invalidRecord
            }
            for key in record.targetKeys {
                let parts = key.split(separator: "\0", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      try PatchPathValidator.canonicalBundleIdentifier(String(parts[0])) == String(parts[0]),
                      try PatchPathValidator.canonicalRelativePath(String(parts[1])) == String(parts[1]) else {
                    throw PatchEngineStateError.invalidRecord
                }
            }
        } else if journal.schemaVersion == 3 { throw PatchEngineStateError.invalidRecord }
        return journal
    }

    private func latestBoundJournal(_ projectID: UUID) throws -> JournalProjection? {
        let root = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        var journals: [JournalProjection] = []
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let transactionID = UUID(uuidString: child.lastPathComponent),
                  FileManager.default.fileExists(atPath: child.appendingPathComponent("journal.plist").path) else { continue }
            journals.append(try readProjection(projectID: projectID, transactionID: transactionID))
        }
        // Multiple unfinished transactions are not a normal predecessor/successor
        // transition. Never hide an older recovery obligation behind a new one.
        let unfinished = journals.filter { !$0.isTerminal }
        guard unfinished.count <= 1 else { throw PatchEngineStateError.invalidRecord }
        if let pending = unfinished.first {
            guard !journals.contains(where: { $0.isTerminal && $0.createdAt > pending.createdAt }) else {
                throw PatchEngineStateError.invalidRecord
            }
            return pending.engineRecord == nil ? nil : pending
        }
        return journals.sorted { $0.createdAt > $1.createdAt }.first.flatMap { $0.engineRecord == nil ? nil : $0 }
    }

    func read(_ projectID: UUID) throws -> PatchEngineApplicationRecord? {
        let target = url(projectID)
        var sidecar: PatchEngineApplicationRecord?
        if FileManager.default.fileExists(atPath: target.path) {
            let data = try Data(contentsOf: target)
            guard data.count <= Self.maximumRecordBytes,
                  let record = try? PropertyListDecoder().decode(PatchEngineApplicationRecord.self, from: data),
                  record.projectID == projectID else { throw PatchEngineStateError.invalidRecord }
            try record.validate(); sidecar = record
        }
        guard let journal = try latestBoundJournal(projectID), var bound = journal.engineRecord else { return sidecar }
        if let sidecar, sidecar.engine == .airLift, journal.isTerminal {
            // A later AirLift application has no direct backup. A terminal
            // direct journal must not hide that new unbacked obligation or
            // make its old baseline appear restorable after AirLift writes.
            return sidecar
        }
        if let sidecar {
            if sidecar.journalID == bound.journalID {
                guard sidecar.operationID == bound.operationID, sidecar.engine == bound.engine,
                      sidecar.baseline == bound.baseline, sidecar.targetKeys == bound.targetKeys else {
                    throw PatchEngineStateError.invalidRecord
                }
            } else {
                // A stale project index may only be replaced by a newer bound
                // journal after proving the previous direct journal terminated.
                guard sidecar.engine != .airLift, sidecar.baseline != .legacyUnknown,
                      let previousID = sidecar.journalID, sidecar.operationID == previousID else {
                    throw PatchEngineStateError.invalidRecord
                }
                let previous = try readProjection(projectID: projectID, transactionID: previousID)
                guard previous.isTerminal, previous.createdAt <= journal.createdAt else {
                    throw PatchEngineStateError.invalidRecord
                }
            }
        }
        switch journal.status {
        case "prepared": bound.phase = .recoveryRequired
        case "applied": bound.phase = .applied
        default: bound.phase = .restored
        }
        return bound
    }
    func save(_ record: PatchEngineApplicationRecord) throws {
        let data = try Self.encodedRecord(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(record.projectID), options: .atomic)
    }
    func requireResolvedLegacyHistory(defaults: UserDefaults = .standard) throws {
        let prefix = "airlift.applied."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard (value as? NSNumber)?.boolValue == true || value as? Bool == true else { continue }
            guard let projectID = UUID(uuidString: String(key.dropFirst(prefix.count))),
                  try read(projectID) != nil else { throw PatchEngineStateError.legacyTargetsUnknown }
        }
    }
    func requireNoUnbackedOverlap(projectID: UUID, targetKeys: [String], includingBackedApplications: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where item.pathExtension == "plist" {
            guard let id = UUID(uuidString: item.deletingPathExtension().lastPathComponent),
                  let record = try read(id) else { throw PatchEngineStateError.invalidRecord }
            guard record.phase != .restored, includingBackedApplications || record.engine == .airLift else { continue }
            if record.projectID == projectID || record.targetKeys.contains(where: { old in
                targetKeys.contains { old == $0 || old.hasPrefix($0 + "/") || $0.hasPrefix(old + "/") }
            }) { throw PatchEngineStateError.recoveryRequired }
        }
    }
    static func reconcile(record: PatchEngineApplicationRecord?, journal: PatchApplicationState?,
                          legacyAirLift: Bool) -> PatchApplicationState? {
        if let record {
            if record.engine == .airLift { return record.applicationState }
            guard let journal else { return .recoveryRequired }
            // A committed journal owns its original bytes and crash recovery;
            // stale preference booleans cannot override a bound new record.
            if journal == .off { return .off }
            return record.phase == .restored ? .recoveryRequired : journal
        }
        if legacyAirLift && journal != nil { return .recoveryRequired }
        if legacyAirLift { return .applied }
        return journal
    }
    static func requireDirectRestore(record: PatchEngineApplicationRecord?, receiptID: UUID?,
                                     journal: PatchApplicationState?, legacyAirLift: Bool) throws {
        if let record {
            guard record.engine != .airLift, record.baseline != .legacyUnknown else { throw PatchEngineStateError.airLiftNoBackup }
            guard record.journalID == receiptID || journal == .off else { throw PatchEngineStateError.invalidRecord }
            return
        }
        if legacyAirLift {
            if journal != nil { throw PatchEngineStateError.legacyAmbiguous }
            throw PatchEngineStateError.airLiftNoBackup
        }
    }
}
// END PATCH ENGINE PROVENANCE

// BEGIN PATCH FILESYSTEM GATE — one owner across asynchronous native writes.
actor PatchFilesystemGate {
    static let shared = PatchFilesystemGate()
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<UUID, Error>)] = []
    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            if owner == nil { owner = id; return id }
            return try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        let waiter = waiters.remove(at: index); waiter.1.resume(throwing: CancellationError())
    }
    func validate(_ id: UUID) throws {
        try Task.checkCancellation()
        guard owner == id else { throw PatchEngineStateError.operationNotHeld }
    }
    func release(_ id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty { owner = nil }
        else { let next = waiters.removeFirst(); owner = next.0; next.1.resume(returning: next.0) }
    }
}

@MainActor
func withExclusivePatchOperation<T>(_ operation: @MainActor (UUID) async throws -> T) async throws -> T {
    let id = try await PatchFilesystemGate.shared.acquire()
    do {
        try await PatchFilesystemGate.shared.validate(id)
        let result = try await operation(id)
        await PatchFilesystemGate.shared.release(id)
        return result
    } catch { await PatchFilesystemGate.shared.release(id); throw error }
}
// END PATCH FILESYSTEM GATE

/// Preferences associate catalog items with transaction journals, which own the
/// backups. A missing preference flag must never hide an existing transaction.
struct CatalogPatchApplicationRegistry {
    let defaults: UserDefaults
    private let prefix = "patch_applied_"
    func projectID(for identity: String) -> UUID? {
        defaults.string(forKey: prefix + identity + "_projectID").flatMap(UUID.init(uuidString:))
    }
    func associate(_ projectID: UUID, with identity: String) {
        defaults.set(projectID.uuidString, forKey: prefix + identity + "_projectID")
    }
    /// Adopt legacy slug-based preferences without deleting their journal or
    /// overwriting a newer stable association. Repeat calls are harmless.
    func migrateIdentity(from legacy: String, to stable: String) {
        guard legacy != stable else { return }
        let oldID = projectID(for: legacy), currentID = projectID(for: stable)
        guard currentID == nil || currentID == oldID else { return }
        guard oldID != nil || defaults.bool(forKey: prefix + legacy)
                || defaults.bool(forKey: prefix + legacy + "_recovery") else { return }
        if let oldID { associate(oldID, with: stable) }
        for suffix in ["", "_recovery"] where defaults.bool(forKey: prefix + legacy + suffix) {
            defaults.set(true, forKey: prefix + stable + suffix)
        }
        // Preference keys only; the transaction journal/backups are untouched.
        // Leaving old ON flags would resurrect them after a successful restore.
        clear(legacy)
    }
    func markApplied(_ identity: String) {
        defaults.set(true, forKey: prefix + identity)
        defaults.removeObject(forKey: prefix + identity + "_recovery")
    }
    func markRecoveryRequired(_ identity: String) {
        defaults.set(true, forKey: prefix + identity + "_recovery")
    }
    func clear(_ identity: String) {
        for suffix in ["", "_projectID", "_recovery"] { defaults.removeObject(forKey: prefix + identity + suffix) }
    }
    func state(for identity: String, recordedState: (UUID) -> PatchApplicationState?) -> PatchApplicationState {
        if let id = projectID(for: identity), let state = recordedState(id) {
            if state == .off { return .off }
            return defaults.bool(forKey: prefix + identity + "_recovery") ? .recoveryRequired : state
        }
        return defaults.bool(forKey: prefix + identity) || defaults.bool(forKey: prefix + identity + "_recovery")
            ? .recoveryRequired : .off
    }
}

enum PatchTransaction {
    /// Pins directories for one synchronous transaction. Every target lookup uses
    /// openat without following links, and commit uses the pinned parent FD. A name
    /// being replaced by another process can never redirect rename/unlink outside
    /// the directory that was validated and backed up.
    private final class PatchTargetFilesystem: NSObject {
        private final class Directory {
            let descriptor: Int32
            init(_ descriptor: Int32) { self.descriptor = descriptor }
            deinit { close(descriptor) }
        }
        var isRollingBack = false
        private var roots: [String: Directory] = [:]
        private var directories: [String: Directory] = [:]
        private let previous: Any?
        static let contextKey = "astra.patch.target-filesystem"

        init(install: Bool) {
            previous = Thread.current.threadDictionary[Self.contextKey]
            super.init()
            if install { Thread.current.threadDictionary[Self.contextKey] = self }
        }
        func finish() {
            if let previous { Thread.current.threadDictionary[Self.contextKey] = previous }
            else { Thread.current.threadDictionary.removeObject(forKey: Self.contextKey) }
        }
        private func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil) }
        private func openedDirectory(_ name: String, at parent: Int32) throws -> Directory {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw failure() }
            return Directory(fd)
        }
        private func openAbsolute(_ path: String) throws -> Directory {
            // The verified canonical container root may be accessible under a
            // scoped grant even though its system-owned parents cannot be listed.
            // Open that root directly, then walk only relative descendants below it.
            try openedDirectory(path, at: AT_FDCWD)
        }
        func prepare(_ target: URL, root: URL, allowMissing: Bool) throws {
            let rootPath = root.standardizedFileURL.path
            if roots[rootPath] == nil {
                let directory = try openAbsolute(rootPath)
                roots[rootPath] = directory
                directories[rootPath] = directory
            }
            _ = try parent(of: target, allowMissing: allowMissing)
        }
        func owns(_ url: URL) -> Bool {
            roots.keys.contains { url.path.hasPrefix($0 + "/") }
        }
        func parent(of url: URL, allowMissing: Bool = false) throws -> Int32? {
            let path = url.deletingLastPathComponent().standardizedFileURL.path
            if let known = directories[path] { return known.descriptor }
            guard let root = roots.keys.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }),
                  var current = roots[root] else { throw PatchEngineStateError.invalidRecord }
            var currentPath = root
            for component in path.dropFirst(root.count).split(separator: "/") {
                currentPath += "/" + component
                if let known = directories[currentPath] { current = known; continue }
                do {
                    current = try openedDirectory(String(component), at: current.descriptor)
                    directories[currentPath] = current
                } catch {
                    if allowMissing && errno == ENOENT { return nil }
                    throw error
                }
            }
            return current.descriptor
        }
        func statItem(_ url: URL) throws -> stat? {
            guard let parent = try parent(of: url, allowMissing: true) else { return nil }
            var metadata = stat()
            guard fstatat(parent, url.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw failure()
            }
            guard isRollingBack || metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            return metadata
        }
        func openRead(_ url: URL) throws -> Int32 {
            guard let parent = try parent(of: url) else { throw PatchEngineStateError.invalidRecord }
            let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw failure() }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                close(fd); throw PatchEngineStateError.invalidRecord
            }
            return fd
        }
        func createDirectory(_ url: URL) throws {
            guard let parent = try parent(of: url) else { throw PatchEngineStateError.invalidRecord }
            guard mkdirat(parent, url.lastPathComponent, mode_t(0o755)) == 0 else { throw failure() }
            directories[url.path] = try openedDirectory(url.lastPathComponent, at: parent)
        }
        func remove(_ url: URL, directory: Bool = false) throws {
            guard let parent = try parent(of: url, allowMissing: true) else { return }
            guard unlinkat(parent, url.lastPathComponent, directory ? AT_REMOVEDIR : 0) == 0 else {
                if errno == ENOENT { return }
                throw failure()
            }
            if directory { directories.removeValue(forKey: url.path) }
        }
        func validateBindings() throws {
            for (path, pinned) in directories {
                guard let root = roots.keys.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else {
                    throw PatchEngineStateError.invalidRecord
                }
                var current = try openAbsolute(root)
                for component in path.dropFirst(root.count).split(separator: "/") {
                    current = try openedDirectory(String(component), at: current.descriptor)
                }
                var expected = stat(), actual = stat()
                guard fstat(pinned.descriptor, &expected) == 0, fstat(current.descriptor, &actual) == 0,
                      expected.st_dev == actual.st_dev, expected.st_ino == actual.st_ino else {
                    throw PatchEngineStateError.invalidRecord
                }
            }
        }
    }

    private static var targetFilesystem: PatchTargetFilesystem? {
        Thread.current.threadDictionary[PatchTargetFilesystem.contextKey] as? PatchTargetFilesystem
    }
    private enum Status: String, Codable {
        case prepared
        case applied
        case rolledBack
        case restored
    }

    private struct Record: Codable {
        let ruleID: UUID
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
        let originalExisted: Bool
        let backupFilename: String?
        let originalDigest: Data?
        let replacementDigest: Data
        let appliedFilename: String?
    }

    private struct DirectoryRecord: Codable {
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
        let device: UInt64?
        let inode: UInt64?

        init(bundleID: String, relativePath: String, containerFingerprint: Data,
             device: UInt64? = nil, inode: UInt64? = nil) {
            self.bundleID = bundleID; self.relativePath = relativePath
            self.containerFingerprint = containerFingerprint
            self.device = device; self.inode = inode
        }
    }

    private struct ResolvedCreatedDirectory {
        let target: URL
        let device: UInt64
        let inode: UInt64
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        let transactionID: UUID
        let projectID: UUID
        let createdAt: Date
        var status: Status
        let records: [Record]
        var createdDirectories: [DirectoryRecord]?
        let engineRecord: PatchEngineApplicationRecord?
        let declaredDirectories: [DirectoryRecord]?
    }

    private struct ResolvedRule {
        let rule: PatchRule
        let containerRoot: URL
        let target: URL
    }

    private struct ResolvedDirectory {
        let bundleID: String
        let relativePath: String
        let containerRoot: URL
        let target: URL
    }

    private struct ResolvedRecord {
        let record: Record
        let target: URL
    }

    private struct CurrentFileSnapshot {
        let target: URL
        let existed: Bool
        let snapshotURL: URL?
    }

    private enum AppliedSource {
        case file(URL)
        case data(Data)
    }

    private static let minimumSchemaVersion = 1
    private static let schemaVersion = 3
    private static let journalFilename = "journal.plist"
    private static let prewriteFilename = ".prewrite.plist"
    private struct PrewriteMarker: Codable {
        let schema: Int
        let projectID: UUID
        let transactionID: UUID
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { close(descriptor) }
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixFailure()
        }
    }

    private static func writePrewriteMarker(projectID: UUID, transactionID: UUID, directory: URL) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let url = directory.appendingPathComponent(prewriteFilename)
        try encoder.encode(PrewriteMarker(schema: 1, projectID: projectID, transactionID: transactionID)).write(to: url, options: .atomic)
        let descriptor = open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { close(descriptor) }
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixFailure()
        }
        try synchronizeDirectory(directory)
    }

    private static func finishPrewritePhase(directory: URL) throws {
        // Remove and synchronize BEFORE any target mutation. An orphan backup
        // with no valid marker is unknown state, never a new trusted baseline.
        let marker = directory.appendingPathComponent(prewriteFilename)
        guard unlink(marker.path) == 0 else { throw posixFailure() }
        try synchronizeDirectory(directory)
    }

    private static func isSafePrewriteDirectory(_ directory: URL, projectID: UUID, fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        // Even an empty legacy transaction can have created new target files
        // (private projects keep no applied payload and had no original file).
        // Only an explicit durable no-mutation marker proves a harmless draft.
        _ = contents
        let url = directory.appendingPathComponent(prewriteFilename)
        guard let data = try? Data(contentsOf: url), data.count <= 4096,
              let marker = try? PropertyListDecoder().decode(PrewriteMarker.self, from: data),
              marker.schema == 1, marker.projectID == projectID,
              marker.transactionID.uuidString == directory.lastPathComponent else { return false }
        return true
    }

    static func apply(
        project: PatchProject,
        backupRoot: URL,
        engine: PatchWriteEngine = .legacy3105,
        allowOverlappingTargets: Bool = false,
        containerResolver: (String) throws -> URL,
        beforeWrite: ((Int) throws -> Void)? = nil,
        beforeDirectoryCreate: ((Int) throws -> Void)? = nil,
        beforeProvenanceWrite: (() throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> PatchTransactionReceipt {
        let targetScope = PatchTargetFilesystem(install: true)
        defer { targetScope.finish() }
        try DirectPatchExecutionContext.check()
        guard !project.rules.isEmpty || !project.directories.isEmpty else {
            throw PatchPackageError.invalidProject
        }
        // A damaged journal is unknown state, not evidence that a patch is OFF.
        // Never take a new baseline from possibly patched bytes in that state.
        if !allowOverlappingTargets { try requireReadableTransactionHistory(backupRoot: backupRoot, fileManager: fileManager) }
        guard latestReceipt(
            projectID: project.id,
            backupRoot: backupRoot,
            fileManager: fileManager
        ) == nil else {
            throw PatchPackageError.projectAlreadyApplied
        }
        let engineStore = PatchEngineApplicationStore(backupRoot: backupRoot)
        if !allowOverlappingTargets { try engineStore.requireResolvedLegacyHistory() }
        let previousEngine = try engineStore.read(project.id)
        let legacyAirLift = UserDefaults.standard.bool(forKey: "airlift.applied.\(project.id.uuidString)")
        if previousEngine == nil && legacyAirLift { throw PatchEngineStateError.airLiftNoBackup }
        let engineTargets = (project.rules.map { $0.bundleID + "\0" + $0.relativePath }
            + project.directories.map { $0.bundleID + "\0" + $0.relativePath }).sorted()
        if !allowOverlappingTargets {
            try engineStore.requireNoUnbackedOverlap(projectID: project.id, targetKeys: engineTargets)
        }
        let transactionID = UUID()
        var engineRecord = PatchEngineApplicationRecord(projectID: project.id, operationID: transactionID,
            engine: engine, baseline: .capturedPriorState, targetKeys: engineTargets, journalID: transactionID)
        // Use the exact reader cap before resolving a target or creating backups.
        _ = try PatchEngineApplicationStore.encodedRecord(engineRecord)

        var roots: [String: URL] = [:]
        var resolvedRules: [ResolvedRule] = []
        var resolvedDirectories: [ResolvedDirectory] = []
        var targetKeys = Set<String>()

        func resolvedRoot(for bundleID: String) throws -> URL {
            if let cached = roots[bundleID] { return cached }
            let root = PatchPathValidator.canonicalFileURL(try containerResolver(bundleID))
            roots[bundleID] = root
            return root
        }

        var requestedDirectories = Set<String>()
        for directory in project.directories {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(directory.bundleID)
            guard bundleID == directory.bundleID else { throw PatchPackageError.invalidProject }
            requestedDirectories.insert(bundleID + "\0" + directory.relativePath)
        }
        for rule in project.rules {
            let components = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
                .split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                requestedDirectories.insert(
                    rule.bundleID + "\0" + components.prefix(count).joined(separator: "/")
                )
            }
        }

        for key in requestedDirectories.sorted(by: directoryKeySort) {
            let parts = key.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw PatchPackageError.invalidProject }
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(String(parts[0]))
            let relativePath = try PatchPathValidator.canonicalRelativePath(String(parts[1]))
            let root = try resolvedRoot(for: bundleID)
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: relativePath,
                containerRoot: root
            )
            try validateDirectoryTarget(
                target,
                relativePath: relativePath,
                containerRoot: root,
                fileManager: fileManager
            )
            resolvedDirectories.append(ResolvedDirectory(
                bundleID: bundleID,
                relativePath: relativePath,
                containerRoot: root,
                target: target
            ))
        }

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            guard bundleID == rule.bundleID else { throw PatchPackageError.invalidProject }
            let root = try resolvedRoot(for: rule.bundleID)
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: rule.relativePath,
                containerRoot: root
            )
            let targetKey = target.path
            guard targetKeys.insert(targetKey).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            try validateFileTarget(
                target,
                relativePath: rule.relativePath,
                containerRoot: root,
                allowMissingParents: true,
                fileManager: fileManager
            )
            resolvedRules.append(ResolvedRule(rule: rule, containerRoot: root, target: target))
        }

        let occupied = allowOverlappingTargets ? Set<String>() : appliedTargetKeys(
            backupRoot: backupRoot,
            excludingProjectID: project.id,
            fileManager: fileManager
        )
        for resolved in resolvedRules {
            let occupancyKey = resolved.rule.bundleID + "\0" + resolved.rule.relativePath
            if !allowOverlappingTargets && occupied.contains(occupancyKey) {
                throw PatchPackageError.targetOccupied(
                    resolved.rule.bundleID + "/" + resolved.rule.relativePath
                )
            }
        }

        let transactionDirectory = backupRoot
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
            try synchronizeDirectory(transactionDirectory.deletingLastPathComponent())
            try synchronizeDirectory(backupRoot)
            try writePrewriteMarker(projectID: project.id, transactionID: transactionID, directory: transactionDirectory)
        } catch {
            throw failedApply(error, operation: "backup-directory")
        }

        var records: [Record] = []
        let plannedDirectories = try resolvedDirectories.compactMap { resolved -> DirectoryRecord? in
            guard try !targetExists(resolved.target, fileManager: fileManager) else { return nil }
            return DirectoryRecord(
                bundleID: resolved.bundleID,
                relativePath: resolved.relativePath,
                containerFingerprint: containerFingerprint(resolved.containerRoot)
            )
        }
        do {
            for resolved in resolvedRules {
                try DirectPatchExecutionContext.check()
                let existed = try targetExists(resolved.target, fileManager: fileManager)
                let backupFilename = existed ? "\(resolved.rule.id.uuidString).original" : nil
                let appliedFilename = project.isPrivate
                    ? nil
                    : "\(resolved.rule.id.uuidString).applied"
                var originalDigest: Data?
                if let backupFilename {
                    let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                    try fileOperation("backup-copy") { try atomicCopy(resolved.target, to: backupURL, fileManager: fileManager) }
                    originalDigest = try fileOperation("backup-read") { try digestFile(backupURL) }
                }
                let replacementDigest = digest(resolved.rule.replacementData)
                if let appliedFilename {
                    let appliedURL = transactionDirectory.appendingPathComponent(appliedFilename)
                    try fileOperation("applied-payload-write") { try resolved.rule.replacementData.write(to: appliedURL, options: .atomic) }
                    guard try fileOperation("applied-payload-verify", { try digestFile(appliedURL) }) == replacementDigest else {
                        throw PatchPackageError.applyFailed
                    }
                }
                records.append(Record(
                    ruleID: resolved.rule.id,
                    bundleID: resolved.rule.bundleID,
                    relativePath: resolved.rule.relativePath,
                    containerFingerprint: containerFingerprint(resolved.containerRoot),
                    originalExisted: existed,
                    backupFilename: backupFilename,
                    originalDigest: originalDigest,
                    replacementDigest: replacementDigest,
                    appliedFilename: appliedFilename
                ))
            }
        } catch let error as PatchPackageError {
            throw error
        } catch {
            throw failedApply(error, operation: "backup")
        }

        let journalURL = transactionDirectory.appendingPathComponent(journalFilename)
        var journal = Journal(
            schemaVersion: schemaVersion,
            transactionID: transactionID,
            projectID: project.id,
            createdAt: Date(),
            status: .prepared,
            records: records,
            createdDirectories: plannedDirectories,
            engineRecord: engineRecord,
            declaredDirectories: project.directories.map { directory in
                DirectoryRecord(bundleID: directory.bundleID, relativePath: directory.relativePath,
                    containerFingerprint: containerFingerprint(roots[directory.bundleID]!))
            }
        )
        do {
            try writeJournal(journal, to: journalURL)
        } catch {
            throw failedApply(error, operation: "journal-write")
        }

        // The first atomic journal already binds its immutable provenance to
        // the backups. Rebuild a missing/stale project index only after the
        // journal and predecessor binding checks in applicationStore.read.
        try fileOperation("provenance-write") {
            try beforeProvenanceWrite?()
            try saveEngineRecord(engineRecord, in: engineStore)
        }
        try fileOperation("prewrite-finish") { try finishPrewritePhase(directory: transactionDirectory) }

        var attemptedRecords: [Record] = []
        var actualCreatedDirectories: [DirectoryRecord] = []
        let missingKeys = Set(plannedDirectories.map { $0.bundleID + "\0" + $0.relativePath })
        do {
            for (index, resolved) in resolvedDirectories.filter({ missingKeys.contains($0.bundleID + "\0" + $0.relativePath) }).enumerated() {
                try DirectPatchExecutionContext.check()
                try beforeDirectoryCreate?(index)
                try DirectPatchExecutionContext.check()
                // Another process creating a planned-missing name does not
                // transfer ownership of that directory to this transaction.
                guard try !targetExists(resolved.target, fileManager: fileManager) else { throw PatchEngineStateError.recoveryRequired }
                try fileOperation("target-directory-create") {
                    try targetFilesystem!.createDirectory(resolved.target)
                }
                guard let metadata = try targetFilesystem?.statItem(resolved.target),
                      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw PatchEngineStateError.invalidRecord }
                actualCreatedDirectories.append(DirectoryRecord(bundleID: resolved.bundleID,
                    relativePath: resolved.relativePath, containerFingerprint: containerFingerprint(resolved.containerRoot),
                    device: UInt64(truncatingIfNeeded: metadata.st_dev), inode: UInt64(truncatingIfNeeded: metadata.st_ino)))
            }
            journal.createdDirectories = actualCreatedDirectories
            // A crash before this durable update leaves only unknown planned
            // directories, which recovery preserves instead of claiming them.
            try writeJournal(journal, to: journalURL)
            for (index, resolved) in resolvedRules.enumerated() {
                try DirectPatchExecutionContext.check()
                try beforeWrite?(index)
                try DirectPatchExecutionContext.check()
                attemptedRecords.append(records[index])
                try atomicWrite(
                    resolved.rule.replacementData,
                    to: resolved.target,
                    preservingExistingAttributes: true,
                    fileManager: fileManager
                )
                guard try fileOperation("target-readback", { try digestFile(resolved.target) }) == records[index].replacementDigest else {
                    throw PatchPackageError.applyFailed
                }
            }
            try DirectPatchExecutionContext.check()
            try targetFilesystem?.validateBindings()
            journal.status = .applied
            try writeJournal(journal, to: journalURL)
            engineRecord.phase = .applied
            try fileOperation("provenance-write") { try saveEngineRecord(engineRecord, in: engineStore) }
            return PatchTransactionReceipt(
                id: transactionID,
                projectID: project.id,
                journalURL: journalURL
            )
        } catch {
            var failure = filesystemFailure(error, operation: "transaction-write")
            do {
                targetFilesystem?.isRollingBack = true
                defer { targetFilesystem?.isRollingBack = false }
                try restoreRecords(
                    attemptedRecords,
                    transactionDirectory: transactionDirectory,
                    roots: roots,
                    requirePatchedDigest: false,
                    createdDirectories: actualCreatedDirectories,
                    fileManager: fileManager
                )
                journal.createdDirectories = actualCreatedDirectories
                journal.status = .rolledBack
                try writeJournal(journal, to: journalURL)
                engineRecord.phase = .restored
                try saveEngineRecord(engineRecord, in: engineStore)
                failure?.rollbackCompleted = true
            } catch {
                // Preserve the prepared journal and backups for explicit recovery.
                if failure == nil {
                    failure = filesystemFailure(error, operation: "rollback")
                }
                engineRecord.phase = .recoveryRequired
                try? saveEngineRecord(engineRecord, in: engineStore)
                failure?.rollbackCompleted = false
            }
            if let failure { throw failure }
            throw PatchPackageError.applyFailed
        }
    }

    static func inspectRestore(
        receipt: PatchTransactionReceipt,
        containerResolver: (String) throws -> URL,
        fileManager: FileManager = .default
    ) throws -> PatchRestoreInspection {
        let targetScope = PatchTargetFilesystem(install: true)
        defer { targetScope.finish() }
        let backupRoot = receipt.journalURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store = PatchEngineApplicationStore(backupRoot: backupRoot)
        try PatchEngineApplicationStore.requireDirectRestore(record: try store.read(receipt.projectID), receiptID: receipt.id,
            journal: try recordedApplicationState(receipt: receipt),
            legacyAirLift: UserDefaults.standard.bool(forKey: "airlift.applied.\(receipt.projectID.uuidString)"))
        do {
            let journal = try activeJournal(for: receipt)
            let roots = try resolvedRoots(
                journal: journal,
                containerResolver: containerResolver
            )
            let resolved = try resolvedRecords(
                journal.records,
                transactionDirectory: receipt.journalURL.deletingLastPathComponent(),
                roots: roots,
                allowMissingParents: journal.status == .prepared,
                fileManager: fileManager
            )
            return PatchRestoreInspection(
                changedTargets: try restoreChanges(in: resolved, prepared: journal.status == .prepared, fileManager: fileManager),
                currentStateSnapshot: try currentStateSnapshot(receipt: receipt, resolved: resolved, fileManager: fileManager)
            )
        } catch {
            throw PatchPackageError.restoreFailed
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowChangedTargets: Bool = false,
        expectedCurrentState: Data? = nil,
        preserveLaterPatches: Bool = false,
        containerResolver: (String) throws -> URL,
        beforeWrite: ((Int) throws -> Void)? = nil,
        beforeRestoreVerification: (() throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws {
        let targetScope = PatchTargetFilesystem(install: true)
        defer { targetScope.finish() }
        let backupRoot = receipt.journalURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engineStore = PatchEngineApplicationStore(backupRoot: backupRoot)
        let engineRecord = try engineStore.read(receipt.projectID)
        try PatchEngineApplicationStore.requireDirectRestore(record: engineRecord, receiptID: receipt.id,
            journal: try recordedApplicationState(receipt: receipt),
            legacyAirLift: UserDefaults.standard.bool(forKey: "airlift.applied.\(receipt.projectID.uuidString)"))
        do {
            var journal = try activeJournal(for: receipt)
            let transactionDirectory = receipt.journalURL.deletingLastPathComponent()
            let roots = try resolvedRoots(
                journal: journal,
                containerResolver: containerResolver
            )
            var resolved = try resolvedRecords(
                journal.records,
                transactionDirectory: transactionDirectory,
                roots: roots,
                allowMissingParents: journal.status == .prepared,
                fileManager: fileManager
            )
            if preserveLaterPatches {
                let directories = try fileManager.contentsOfDirectory(at: backupRoot,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                var newer = Set<String>()
                for directory in directories {
                    guard let id = UUID(uuidString: directory.lastPathComponent), id != receipt.projectID,
                          let other = latestReceipt(projectID: id, backupRoot: backupRoot),
                          let history = try? readJournal(other.journalURL),
                          history.createdAt > journal.createdAt,
                          history.status == .applied || history.status == .prepared else { continue }
                    newer.formUnion(history.records.map { $0.bundleID + "\0" + $0.relativePath })
                }
                resolved.removeAll { newer.contains($0.record.bundleID + "\0" + $0.record.relativePath) }
            }
            let changes = try restoreChanges(in: resolved, prepared: journal.status == .prepared, fileManager: fileManager)
            if let expectedCurrentState,
               try currentStateSnapshot(receipt: receipt, resolved: resolved, fileManager: fileManager) != expectedCurrentState {
                throw PatchPackageError.restoreTargetsChanged(resolved.map { $0.record.bundleID + "/" + $0.record.relativePath })
            }
            if !changes.isEmpty, !allowChangedTargets {
                throw PatchPackageError.restoreTargetsChanged(changes.map(\.displayPath))
            }
            let createdDirectoryURLs = try resolvedCreatedDirectories(
                journal.createdDirectories ?? [],
                roots: roots,
                fileManager: fileManager
            )

            let capturedTargetStates = try Dictionary(uniqueKeysWithValues: resolved.map {
                ($0.target.path, try fileStateDigest($0.target, fileManager: fileManager))
            })
            try withCurrentStateRecovery(
                resolved,
                transactionDirectory: transactionDirectory,
                fileManager: fileManager
            ) { willMutate in
                if let expectedCurrentState,
                   try currentStateSnapshot(receipt: receipt, resolved: resolved, fileManager: fileManager) != expectedCurrentState {
                    throw PatchPackageError.restoreTargetsChanged(resolved.map { $0.record.bundleID + "/" + $0.record.relativePath })
                }
                for (index, item) in resolved.reversed().enumerated() {
                    try DirectPatchExecutionContext.check()
                    try beforeWrite?(index)
                    try DirectPatchExecutionContext.check()
                    guard try fileStateDigest(item.target, fileManager: fileManager) == capturedTargetStates[item.target.path] else {
                        throw PatchPackageError.restoreTargetsChanged([item.record.bundleID + "/" + item.record.relativePath])
                    }
                    willMutate(item.target)
                    if item.record.originalExisted {
                        let backup = transactionDirectory.appendingPathComponent(
                            item.record.backupFilename!
                        )
                        try atomicCopy(backup, to: item.target, fileManager: fileManager)
                    } else if try targetExists(item.target, fileManager: fileManager) {
                        try removeTarget(item.target, fileManager: fileManager)
                    }
                }
                try beforeRestoreVerification?()
                try verifyRestoredRecords(resolved)
                try DirectPatchExecutionContext.check()
                try targetFilesystem?.validateBindings()
                journal.status = .restored
                try writeJournal(journal, to: receipt.journalURL)
            }

            if !preserveLaterPatches { removeEmptyCreatedDirectories(createdDirectoryURLs, fileManager: fileManager) }
            var restored = engineRecord ?? PatchEngineApplicationRecord(projectID: receipt.projectID,
                operationID: receipt.id, engine: .legacy3105, baseline: .capturedPriorState,
                targetKeys: journal.records.map { $0.bundleID + "\0" + $0.relativePath }
                    + (journal.createdDirectories ?? []).map { $0.bundleID + "\0" + $0.relativePath }, journalID: receipt.id)
            restored.phase = .restored
            try saveEngineRecord(restored, in: engineStore)
        } catch let error as PatchPackageError {
            if case .restoreTargetsChanged = error { throw error }
            throw PatchPackageError.restoreFailed
        } catch {
            throw PatchPackageError.restoreFailed
        }
    }

    static func resetToAppliedState(
        receipt: PatchTransactionReceipt,
        fallbackProject: PatchProject? = nil,
        containerResolver: (String) throws -> URL,
        beforeWrite: ((Int) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws {
        let targetScope = PatchTargetFilesystem(install: true)
        defer { targetScope.finish() }
        let backupRoot = receipt.journalURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store = PatchEngineApplicationStore(backupRoot: backupRoot)
        try PatchEngineApplicationStore.requireDirectRestore(record: try store.read(receipt.projectID), receiptID: receipt.id,
            journal: try recordedApplicationState(receipt: receipt),
            legacyAirLift: UserDefaults.standard.bool(forKey: "airlift.applied.\(receipt.projectID.uuidString)"))
        do {
            let journal = try activeJournal(for: receipt)
            guard journal.status == .applied else {
                throw PatchPackageError.resetFailed
            }
            let transactionDirectory = receipt.journalURL.deletingLastPathComponent()
            let roots = try resolvedRoots(
                journal: journal,
                containerResolver: containerResolver
            )
            let resolved = try resolvedRecords(
                journal.records,
                transactionDirectory: transactionDirectory,
                roots: roots,
                fileManager: fileManager
            )
            let fallbackRules = Dictionary(
                uniqueKeysWithValues: (fallbackProject?.rules ?? []).map { ($0.id, $0) }
            )
            let sources = try resolved.map { item -> AppliedSource in
                if let filename = item.record.appliedFilename {
                    let source = transactionDirectory.appendingPathComponent(filename)
                    guard fileManager.fileExists(atPath: source.path),
                          try digestFile(source) == item.record.replacementDigest else {
                        throw PatchPackageError.resetFailed
                    }
                    return .file(source)
                }
                guard let rule = fallbackRules[item.record.ruleID],
                      rule.bundleID == item.record.bundleID,
                      rule.relativePath == item.record.relativePath,
                      digest(rule.replacementData) == item.record.replacementDigest else {
                    throw PatchPackageError.resetFailed
                }
                return .data(rule.replacementData)
            }

            try withCurrentStateRecovery(
                resolved,
                transactionDirectory: transactionDirectory,
                fileManager: fileManager
            ) { willMutate in
                for (index, item) in resolved.enumerated() {
                    try DirectPatchExecutionContext.check()
                    try beforeWrite?(index)
                    try DirectPatchExecutionContext.check()
                    willMutate(item.target)
                    switch sources[index] {
                    case .file(let source):
                        try atomicCopy(
                            source,
                            to: item.target,
                            preservingExistingAttributes: true,
                            fileManager: fileManager
                        )
                    case .data(let data):
                        try atomicWrite(
                            data,
                            to: item.target,
                            preservingExistingAttributes: true,
                            fileManager: fileManager
                        )
                    }
                    guard try digestFile(item.target) == item.record.replacementDigest else {
                        throw PatchPackageError.resetFailed
                    }
                }
                try DirectPatchExecutionContext.check()
                try targetFilesystem?.validateBindings()
            }
        } catch {
            throw PatchPackageError.resetFailed
        }
    }

    static func latestReceipt(
        projectID: UUID,
        backupRoot: URL,
        fileManager: FileManager = .default
    ) -> PatchTransactionReceipt? {
        let projectDirectory = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var validJournals: [(journal: Journal, url: URL)] = []
        for directory in directories {
            let url = directory.appendingPathComponent(journalFilename)
            guard fileManager.fileExists(atPath: url.path) else {
                if !isSafePrewriteDirectory(directory, projectID: projectID, fileManager: fileManager) { return nil }
                continue
            }
            guard let journal = try? readJournal(url),
                  (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
                  journal.projectID == projectID,
                  directory.lastPathComponent == journal.transactionID.uuidString else { return nil }
            if journal.status == .applied || journal.status == .prepared { validJournals.append((journal, url)) }
        }

        guard let latest = validJournals.sorted(by: { $0.journal.createdAt > $1.journal.createdAt }).first else {
            return nil
        }

        return PatchTransactionReceipt(
            id: latest.journal.transactionID,
            projectID: latest.journal.projectID,
            journalURL: latest.url
        )
    }

    static func recordedApplicationState(receipt: PatchTransactionReceipt) throws -> PatchApplicationState {
        let journal = try activeJournal(for: receipt)
        return journal.status == .applied ? .applied : .recoveryRequired
    }

    static func latestRecordedApplicationState(projectID: UUID, backupRoot: URL,
                                               fileManager: FileManager = .default) -> PatchApplicationState? {
        let directory = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        guard let transactions = try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return .recoveryRequired }
        var journals: [Journal] = []
        for transaction in transactions {
            let url = transaction.appendingPathComponent(journalFilename)
            guard fileManager.fileExists(atPath: url.path) else {
                if !isSafePrewriteDirectory(transaction, projectID: projectID, fileManager: fileManager) { return .recoveryRequired }
                continue
            }
            guard let journal = try? readJournal(url),
                  (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
                  journal.projectID == projectID, transaction.lastPathComponent == journal.transactionID.uuidString else {
                return .recoveryRequired
            }
            journals.append(journal)
        }
        guard let journal = journals.max(by: { $0.createdAt < $1.createdAt }) else {
            do {
                if let record = try PatchEngineApplicationStore(backupRoot: backupRoot).read(projectID),
                   record.phase != .restored { return .recoveryRequired }
            } catch { return .recoveryRequired }
            return nil
        }
        switch journal.status {
        case .applied: return .applied
        case .prepared: return .recoveryRequired
        case .restored, .rolledBack: return .off
        }
    }

    private static func requireReadableTransactionHistory(backupRoot: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: backupRoot.path) else { return }
        let projects = try fileManager.contentsOfDirectory(at: backupRoot,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for project in projects {
            guard let projectID = UUID(uuidString: project.lastPathComponent) else { continue }
            for transaction in try fileManager.contentsOfDirectory(at: project,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                let url = transaction.appendingPathComponent(journalFilename)
                guard fileManager.fileExists(atPath: url.path) else {
                    guard isSafePrewriteDirectory(transaction, projectID: projectID, fileManager: fileManager) else {
                        throw PatchEngineStateError.invalidRecord
                    }
                    continue
                }
                guard let journal = try? readJournal(url),
                      (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
                      journal.projectID == projectID,
                      transaction.lastPathComponent == journal.transactionID.uuidString else {
                    throw PatchEngineStateError.invalidRecord
                }
            }
        }
        let records = backupRoot.appendingPathComponent(".engine-applications", isDirectory: true)
        guard fileManager.fileExists(atPath: records.path) else { return }
        let store = PatchEngineApplicationStore(backupRoot: backupRoot)
        for url in try fileManager.contentsOfDirectory(at: records, includingPropertiesForKeys: nil) where url.pathExtension == "plist" {
            guard let projectID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let record = try store.read(projectID) else { throw PatchEngineStateError.invalidRecord }
            guard record.engine != .airLift, record.phase != .restored else { continue }
            guard let journalID = record.journalID else { throw PatchEngineStateError.invalidRecord }
            let journalURL = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
                .appendingPathComponent(journalID.uuidString, isDirectory: true).appendingPathComponent(journalFilename)
            guard let journal = try? readJournal(journalURL),
                  (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
                  journal.projectID == projectID, journal.transactionID == journalID else {
                throw PatchEngineStateError.invalidRecord
            }
        }
    }

    /// Adopt a previous successful write without overwriting its original
    /// backup. A pending, changed or different release requires explicit restore.
    static func inspectExistingApplication(
        receipt: PatchTransactionReceipt,
        project: PatchProject,
        containerResolver: (String) throws -> URL,
        fileManager: FileManager = .default
    ) throws -> PatchApplicationState {
        let targetScope = PatchTargetFilesystem(install: true)
        defer { targetScope.finish() }
        let journal = try activeJournal(for: receipt)
        guard project.id == journal.projectID else { throw PatchPackageError.invalidProject }
        guard journal.status == .applied, journal.records.count == project.rules.count,
              Set(project.rules.map(\.id)).count == project.rules.count else { return .recoveryRequired }
        let rules = Dictionary(uniqueKeysWithValues: project.rules.map { ($0.id, $0) })
        guard journal.records.allSatisfy({ record in
            guard let rule = rules[record.ruleID] else { return false }
            return rule.bundleID == record.bundleID && rule.relativePath == record.relativePath
                && digest(rule.replacementData) == record.replacementDigest
        }) else { return .recoveryRequired }
        let roots = try resolvedRoots(journal: journal, containerResolver: containerResolver)
        let requestedDirectoryKeys = Set(try project.directories.map {
            try PatchPathValidator.canonicalBundleIdentifier($0.bundleID) + "\0" + PatchPathValidator.canonicalRelativePath($0.relativePath)
        })
        let fileKeys = Set(journal.records.map { $0.bundleID + "\0" + $0.relativePath })
        let boundRecord = try journal.engineRecord ?? PatchEngineApplicationStore(
            backupRoot: receipt.journalURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        ).read(receipt.projectID)
        let boundDirectoryKeys = boundRecord.map { Set($0.targetKeys).subtracting(fileKeys) }
        let recordedDirectoryKeys = journal.declaredDirectories.map { Set($0.map { $0.bundleID + "\0" + $0.relativePath }) }
            ?? boundDirectoryKeys
        guard requestedDirectoryKeys.isEmpty ? (recordedDirectoryKeys?.isEmpty ?? true)
                : recordedDirectoryKeys == requestedDirectoryKeys,
              boundDirectoryKeys == nil || recordedDirectoryKeys == boundDirectoryKeys else { return .recoveryRequired }
        for directory in project.directories {
            let root = try roots[directory.bundleID] ?? PatchPathValidator.canonicalFileURL(containerResolver(directory.bundleID))
            let target = try PatchPathValidator.resolveContainedTargetURL(relativePath: directory.relativePath, containerRoot: root)
            try targetScope.prepare(target, root: root, allowMissing: true)
            guard let metadata = try targetScope.statItem(target),
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return .recoveryRequired }
        }
        let records = try resolvedRecords(journal.records, transactionDirectory: receipt.journalURL.deletingLastPathComponent(),
            roots: roots, fileManager: fileManager)
        try targetScope.validateBindings()
        return try changedTargets(in: records, fileManager: fileManager).isEmpty ? .applied : .recoveryRequired
    }

    static func appliedTargetKeys(
        backupRoot: URL,
        excludingProjectID: UUID? = nil,
        fileManager: FileManager = .default
    ) -> Set<String> {
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var keys = Set<String>()
        for directory in projectDirectories {
            guard let projectID = UUID(uuidString: directory.lastPathComponent),
                  projectID != excludingProjectID,
                  let receipt = latestReceipt(
                    projectID: projectID,
                    backupRoot: backupRoot,
                    fileManager: fileManager
                  ),
                  let journal = try? readJournal(receipt.journalURL),
                  journal.status == .applied || journal.status == .prepared
            else { continue }
            for record in journal.records {
                keys.insert(record.bundleID + "\0" + record.relativePath)
            }
        }
        return keys
    }

    static func requiredBundleIdentifiers(for receipt: PatchTransactionReceipt) throws -> [String] {
        let journal = try readJournal(receipt.journalURL)
        guard (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID else {
            throw PatchPackageError.restoreFailed
        }
        var seen = Set<String>()
        return (journal.records.map(\.bundleID) + (journal.createdDirectories ?? []).map(\.bundleID)
            + (journal.declaredDirectories ?? []).map(\.bundleID))
            .filter { seen.insert($0).inserted }
    }

    private static func activeJournal(for receipt: PatchTransactionReceipt) throws -> Journal {
        let journal = try readJournal(receipt.journalURL)
        guard (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID,
              journal.status == .applied || journal.status == .prepared else {
            throw PatchPackageError.restoreFailed
        }
        return journal
    }

    private static func resolvedRoots(
        journal: Journal,
        containerResolver: (String) throws -> URL
    ) throws -> [String: URL] {
        var roots: [String: URL] = [:]
        let identities = journal.records.map { ($0.bundleID, $0.containerFingerprint) }
            + (journal.createdDirectories ?? []).map { ($0.bundleID, $0.containerFingerprint) }
            + (journal.declaredDirectories ?? []).map { ($0.bundleID, $0.containerFingerprint) }
        for (bundleID, expectedFingerprint) in identities {
            if let root = roots[bundleID] {
                guard containerFingerprint(root) == expectedFingerprint else {
                    throw PatchPackageError.restoreFailed
                }
                continue
            }
            let root = PatchPathValidator.canonicalFileURL(try containerResolver(bundleID))
            guard containerFingerprint(root) == expectedFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            roots[bundleID] = root
        }
        return roots
    }

    private static func resolvedRecords(
        _ records: [Record],
        transactionDirectory: URL,
        roots: [String: URL],
        allowMissingParents: Bool = false,
        fileManager: FileManager
    ) throws -> [ResolvedRecord] {
        try records.map { record in
            guard let root = roots[record.bundleID],
                  containerFingerprint(root) == record.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: record.relativePath,
                containerRoot: root
            )
            try validateFileTarget(
                target,
                relativePath: record.relativePath,
                containerRoot: root,
                allowMissingParents: allowMissingParents,
                fileManager: fileManager
            )
            if record.originalExisted {
                guard let backupFilename = record.backupFilename,
                      let expectedDigest = record.originalDigest else {
                    throw PatchPackageError.restoreFailed
                }
                let backup = transactionDirectory.appendingPathComponent(backupFilename)
                guard fileManager.fileExists(atPath: backup.path),
                      try digestFile(backup) == expectedDigest else {
                    throw PatchPackageError.restoreFailed
                }
            }
            return ResolvedRecord(record: record, target: target)
        }
    }

    private static func changedTargets(
        in resolved: [ResolvedRecord],
        fileManager: FileManager
    ) throws -> [PatchTargetChange] {
        try resolved.compactMap { item in
            guard try targetExists(item.target, fileManager: fileManager) else {
                return PatchTargetChange(
                    bundleID: item.record.bundleID,
                    relativePath: item.record.relativePath,
                    kind: .missing
                )
            }
            guard try digestFile(item.target) != item.record.replacementDigest else {
                return nil
            }
            return PatchTargetChange(
                bundleID: item.record.bundleID,
                relativePath: item.record.relativePath,
                kind: .modified
            )
        }
    }

    private static func restoreChanges(in resolved: [ResolvedRecord], prepared: Bool,
                                       fileManager: FileManager) throws -> [PatchTargetChange] {
        guard prepared else { return try changedTargets(in: resolved, fileManager: fileManager) }
        // An interrupted prepared transaction may contain either the verified
        // original or replacement bytes. A third state is a later edit and
        // needs the same explicit confirmation as an applied transaction.
        return try resolved.compactMap { item in
            if try !targetExists(item.target, fileManager: fileManager) {
                return item.record.originalExisted
                    ? PatchTargetChange(bundleID: item.record.bundleID, relativePath: item.record.relativePath, kind: .missing)
                    : nil
            }
            let current = try digestFile(item.target)
            if current == item.record.replacementDigest || (item.record.originalExisted && current == item.record.originalDigest) { return nil }
            return PatchTargetChange(bundleID: item.record.bundleID, relativePath: item.record.relativePath, kind: .modified)
        }
    }

    private static func resolvedCreatedDirectories(
        _ directories: [DirectoryRecord], roots: [String: URL], fileManager: FileManager
    ) throws -> [ResolvedCreatedDirectory] {
        try directories.compactMap { directory in
            guard let device = directory.device, let inode = directory.inode else { return nil }
            guard let root = roots[directory.bundleID], containerFingerprint(root) == directory.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let relative = try PatchPathValidator.canonicalRelativePath(directory.relativePath)
            let target = root.appendingPathComponent(relative).standardizedFileURL
            guard let filesystem = targetFilesystem else { return nil }
            try filesystem.prepare(target, root: root, allowMissing: true)
            guard let metadata = try? filesystem.statItem(target),
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  UInt64(truncatingIfNeeded: metadata.st_dev) == device,
                  UInt64(truncatingIfNeeded: metadata.st_ino) == inode else { return nil }
            return ResolvedCreatedDirectory(target: target, device: device, inode: inode)
        }
    }

    private static func withCurrentStateRecovery(
        _ resolved: [ResolvedRecord],
        transactionDirectory: URL,
        fileManager: FileManager,
        operation: (_ willMutate: (URL) -> Void) throws -> Void
    ) throws {
        let recoveryDirectory = transactionDirectory.appendingPathComponent(
            ".recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false)
        var snapshots: [CurrentFileSnapshot] = []
        do {
            for (index, item) in resolved.enumerated() {
                guard try targetExists(item.target, fileManager: fileManager) else {
                    snapshots.append(CurrentFileSnapshot(
                        target: item.target,
                        existed: false,
                        snapshotURL: nil
                    ))
                    continue
                }
                let snapshotURL = recoveryDirectory.appendingPathComponent("\(index).current")
                try atomicCopy(item.target, to: snapshotURL, fileManager: fileManager)
                guard try digestFile(snapshotURL) == digestFile(item.target) else {
                    throw PatchPackageError.restoreFailed
                }
                snapshots.append(CurrentFileSnapshot(
                    target: item.target,
                    existed: true,
                    snapshotURL: snapshotURL
                ))
            }
        } catch {
            try? fileManager.removeItem(at: recoveryDirectory)
            throw error
        }

        var attemptedTargets = Set<String>()
        do {
            try operation { attemptedTargets.insert($0.path) }
        } catch {
            do {
                targetFilesystem?.isRollingBack = true
                defer { targetFilesystem?.isRollingBack = false }
                for snapshot in snapshots.reversed() where attemptedTargets.contains(snapshot.target.path) {
                    if snapshot.existed, let snapshotURL = snapshot.snapshotURL {
                        try atomicCopy(snapshotURL, to: snapshot.target, fileManager: fileManager)
                    } else if try targetExists(snapshot.target, fileManager: fileManager) {
                        try removeTarget(snapshot.target, fileManager: fileManager)
                    }
                }
                try? fileManager.removeItem(at: recoveryDirectory)
            } catch {
                // Keep the recovery directory when rollback cannot complete.
                throw PatchPackageError.restoreFailed
            }
            throw error
        }
        try? fileManager.removeItem(at: recoveryDirectory)
    }

    private static func removeEmptyCreatedDirectories(_ directories: [ResolvedCreatedDirectory], fileManager: FileManager) {
        for directory in directories.reversed() {
            guard let filesystem = targetFilesystem, filesystem.owns(directory.target),
                  let metadata = try? filesystem.statItem(directory.target),
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  UInt64(truncatingIfNeeded: metadata.st_dev) == directory.device,
                  UInt64(truncatingIfNeeded: metadata.st_ino) == directory.inode else { continue }
            // Never recurse. Identity is rechecked immediately before unlink,
            // but POSIX does not offer an inode-conditional unlink primitive;
            // a noncooperating process can still replace a leaf in this window.
            try? filesystem.remove(directory.target, directory: true)
        }
    }

    private static func verifyRestoredRecords(_ resolved: [ResolvedRecord]) throws {
        for item in resolved {
            let metadata: stat?
            if let filesystem = targetFilesystem, filesystem.owns(item.target) {
                metadata = try filesystem.statItem(item.target)
            } else {
                var value = stat()
                let result = lstat(item.target.path, &value)
                if result == 0 { metadata = value }
                else if errno == ENOENT { metadata = nil }
                else { throw posixFailure() }
            }
            if item.record.originalExisted {
                guard let metadata, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      let expected = item.record.originalDigest,
                      try fileOperation("restore-target-readback", { try digestFile(item.target) }) == expected else {
                    throw PatchPackageError.restoreFailed
                }
            } else {
                // Only an actual ENOENT from the anchored stat proves removal;
                // permission or other lookup errors never become OFF.
                guard metadata == nil else { throw PatchPackageError.restoreFailed }
            }
        }
    }

    private static func restoreRecords(
        _ records: [Record],
        transactionDirectory: URL,
        roots: [String: URL],
        requirePatchedDigest: Bool,
        createdDirectories: [DirectoryRecord],
        fileManager: FileManager
    ) throws {
        let createdDirectoryURLs = try resolvedCreatedDirectories(createdDirectories, roots: roots, fileManager: fileManager)

        var restored: [ResolvedRecord] = []
        for record in records.reversed() {
            guard let root = roots[record.bundleID],
                  containerFingerprint(root) == record.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let relative = try PatchPathValidator.canonicalRelativePath(record.relativePath)
            let target = root.appendingPathComponent(relative).standardizedFileURL
            if targetFilesystem?.isRollingBack != true {
                try validateFileTarget(target, relativePath: record.relativePath, containerRoot: root,
                                       allowMissingParents: true, fileManager: fileManager)
            }

            if record.originalExisted {
                guard let backupFilename = record.backupFilename,
                      let expectedDigest = record.originalDigest else {
                    throw PatchPackageError.restoreFailed
                }
                let backup = transactionDirectory.appendingPathComponent(backupFilename)
                guard fileManager.fileExists(atPath: backup.path),
                      try digestFile(backup) == expectedDigest else {
                    throw PatchPackageError.restoreFailed
                }
                if requirePatchedDigest {
                    guard try targetExists(target, fileManager: fileManager),
                          try digestFile(target) == record.replacementDigest else {
                        throw PatchPackageError.restoreFailed
                    }
                }
                try atomicCopy(backup, to: target, fileManager: fileManager)
            } else {
                if requirePatchedDigest {
                    guard try targetExists(target, fileManager: fileManager),
                          try digestFile(target) == record.replacementDigest else {
                        throw PatchPackageError.restoreFailed
                    }
                }
                if try targetExists(target, fileManager: fileManager) {
                    try removeTarget(target, fileManager: fileManager)
                }
            }
            restored.append(ResolvedRecord(record: record, target: target))
        }
        try verifyRestoredRecords(restored)

        removeEmptyCreatedDirectories(createdDirectoryURLs, fileManager: fileManager)
    }

    private static func validateFileTarget(
        _ target: URL,
        relativePath: String,
        containerRoot: URL,
        allowMissingParents: Bool,
        fileManager: FileManager
    ) throws {
        try targetFilesystem?.prepare(target, root: containerRoot, allowMissing: allowMissingParents)
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/")
            .map(String.init)
        var cursor = PatchPathValidator.canonicalFileURL(containerRoot)
        for component in components.dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: cursor.path) else {
                if allowMissingParents { break }
                throw PatchPackageError.applyFailed
            }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
        if try targetExists(target, fileManager: fileManager) {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory != true else {
                throw PatchPackageError.applyFailed
            }
        }
    }

    private static func validateDirectoryTarget(
        _ target: URL,
        relativePath: String,
        containerRoot: URL,
        fileManager: FileManager
    ) throws {
        try targetFilesystem?.prepare(target, root: containerRoot, allowMissing: true)
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/").map(String.init)
        var cursor = PatchPathValidator.canonicalFileURL(containerRoot)
        for component in components {
            cursor.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: cursor.path) else { break }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
        if try targetExists(target, fileManager: fileManager) {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
    }

    private static func directoryKeySort(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.filter { $0 == "/" }.count
        let rightDepth = rhs.filter { $0 == "/" }.count
        return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
    }

    private static func targetExists(_ url: URL, fileManager: FileManager) throws -> Bool {
        if let filesystem = targetFilesystem, filesystem.owns(url) { return try filesystem.statItem(url) != nil }
        return fileManager.fileExists(atPath: url.path)
    }

    private static func openRead(_ url: URL) throws -> Int32 {
        if let filesystem = targetFilesystem, filesystem.owns(url) { return try filesystem.openRead(url) }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posixFailure() }
        return fd
    }

    private static func removeTarget(_ url: URL, fileManager: FileManager) throws {
        if let filesystem = targetFilesystem, filesystem.owns(url) { try filesystem.remove(url) }
        else { try fileManager.removeItem(at: url) }
    }

    private static func stageParent(_ target: URL) throws -> Int32 {
        if let filesystem = targetFilesystem, filesystem.owns(target), let fd = try filesystem.parent(of: target) {
            let result = dup(fd)
            guard result >= 0 else { throw posixFailure() }
            return result
        }
        let fd = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posixFailure() }
        return fd
    }

    private static func copyMetadata(from source: Int32, to destination: Int32) throws {
#if canImport(Darwin)
        guard fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw posixFailure() }
#else
        var metadata = stat()
        guard fstat(source, &metadata) == 0, fchmod(destination, mode_t(metadata.st_mode & 0o7777)) == 0 else { throw posixFailure() }
#endif
    }

    private static func atomicWrite(
        _ data: Data,
        to target: URL,
        preservingExistingAttributes: Bool,
        fileManager: FileManager
    ) throws {
        if targetFilesystem?.isRollingBack != true { try targetFilesystem?.validateBindings() }
        let parent = try stageParent(target)
        defer { close(parent) }
        let name = ".3105-patch-\(UUID().uuidString)"
        let created = try createWritableStage(name, at: parent)
        var descriptor = created.descriptor
        defer { if descriptor >= 0 { close(descriptor) }; unlinkat(parent, name, 0) }
        try fileOperation("staging-write") { try writeAll(data, to: descriptor) }
        if preservingExistingAttributes, try targetExists(target, fileManager: fileManager) {
            let source = try openRead(target)
            defer { close(source) }
            try fileOperation("staging-attributes") { try copyMetadata(from: source, to: descriptor) }
        } else {
            guard fchmod(descriptor, created.defaultPermissions) == 0 else { throw posixFailure() }
        }
        try synchronizeAndClose(&descriptor)
        try commitStage(name, at: parent, to: target.lastPathComponent)
    }

    private static func atomicCopy(
        _ source: URL,
        to target: URL,
        preservingExistingAttributes: Bool = false,
        fileManager: FileManager
    ) throws {
        if targetFilesystem?.isRollingBack != true { try targetFilesystem?.validateBindings() }
        let parent = try stageParent(target)
        defer { close(parent) }
        let name = ".3105-restore-\(UUID().uuidString)"
        var descriptor = try createWritableStage(name, at: parent).descriptor
        defer { if descriptor >= 0 { close(descriptor) }; unlinkat(parent, name, 0) }
        try fileOperation("restore-stage-copy") {
            let sourceDescriptor = try openRead(source)
            defer { close(sourceDescriptor) }
#if canImport(Darwin)
            guard fcopyfile(sourceDescriptor, descriptor, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw posixFailure() }
#else
            var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
            while true {
                let count = read(sourceDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw posixFailure() }
                if count == 0 { break }
                try writeAll(Data(buffer.prefix(count)), to: descriptor)
            }
            try copyMetadata(from: sourceDescriptor, to: descriptor)
#endif
        }
        if preservingExistingAttributes, try targetExists(target, fileManager: fileManager) {
            let sourceDescriptor = try openRead(target)
            defer { close(sourceDescriptor) }
            try fileOperation("restore-stage-attributes") { try copyMetadata(from: sourceDescriptor, to: descriptor) }
        }
        try synchronizeAndClose(&descriptor)
        try commitStage(name, at: parent, to: target.lastPathComponent)
    }

    private static func createWritableStage(_ name: String, at parent: Int32) throws -> (descriptor: Int32, defaultPermissions: mode_t) {
        try fileOperation("staging-create") {
            let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o666))
            guard descriptor >= 0 else { throw posixFailure() }
            do {
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0, fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixFailure() }
                return (descriptor, mode_t(metadata.st_mode & 0o7777))
            } catch {
                close(descriptor); unlinkat(parent, name, 0); throw error
            }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixFailure(count == 0 ? EIO : errno) }
                offset += count
            }
        }
    }

    private static func synchronizeAndClose(_ descriptor: inout Int32) throws {
        try fileOperation("staging-sync") {
            while fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw posixFailure()
            }
        }
        let current = descriptor
        descriptor = -1 // A failed close must never close a reused FD in defer.
        try fileOperation("staging-close") {
            guard close(current) == 0 else { throw posixFailure() }
        }
    }

    private static func commitStage(_ name: String, at parent: Int32, to target: String) throws {
        try fileOperation("target-rename") {
            guard renameat(parent, name, parent, target) == 0 else { throw posixFailure() }
            // Persist the directory entry, not only the staged file bytes.
            while fsync(parent) != 0 {
                if errno == EINTR { continue }
                throw posixFailure()
            }
        }
    }

    private static func posixFailure(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
    }

    private static func filesystemFailure(_ error: Error, operation: String) -> PatchFilesystemFailure? {
        if let known = error as? PatchFilesystemFailure { return known }
        let underlying = error as NSError
        guard underlying.domain == NSPOSIXErrorDomain || (underlying.domain == NSCocoaErrorDomain
            && (underlying.code == NSFileNoSuchFileError || underlying.code == NSFileLockingError
                || (256...1023).contains(underlying.code))) else { return nil }
        return PatchFilesystemFailure(operation: operation, underlying: underlying)
    }

    private static func failedApply(_ error: Error, operation: String) -> Error {
        if let failure = filesystemFailure(error, operation: operation) { return failure }
        return PatchPackageError.applyFailed
    }

    private static func fileOperation<T>(_ operation: String, _ work: () throws -> T) throws -> T {
        do { return try work() }
        catch {
            if let failure = filesystemFailure(error, operation: operation) { throw failure }
            throw error
        }
    }

    private static func synchronizeFile(_ url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { close(descriptor) }
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixFailure()
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func saveEngineRecord(_ record: PatchEngineApplicationRecord, in store: PatchEngineApplicationStore) throws {
        try store.save(record)
        let directory = store.backupRoot.appendingPathComponent(".engine-applications", isDirectory: true)
        try synchronizeFile(directory.appendingPathComponent(record.projectID.uuidString + ".plist"))
        try synchronizeDirectory(store.backupRoot)
    }

    private static func writeJournal(_ journal: Journal, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(journal)
        guard data.count <= PatchEngineApplicationStore.maximumJournalBytes else { throw PatchEngineStateError.invalidRecord }
        try fileOperation("journal-write") {
            try data.write(to: url, options: .atomic)
            try synchronizeFile(url)
        }
    }

    private static func readJournal(_ url: URL) throws -> Journal {
        let data = try Data(contentsOf: url)
        guard data.count <= PatchEngineApplicationStore.maximumJournalBytes else { throw PatchEngineStateError.invalidRecord }
        return try PropertyListDecoder().decode(Journal.self, from: data)
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func digestFile(_ url: URL) throws -> Data {
        let descriptor = try openRead(url)
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw posixFailure() }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return Data(hasher.finalize())
    }

    private static func fileStateDigest(_ url: URL, fileManager: FileManager) throws -> Data {
        let exists = try targetExists(url, fileManager: fileManager)
        return exists ? Data([1]) + (try digestFile(url)) : Data([0])
    }

    private static func currentStateSnapshot(receipt: PatchTransactionReceipt, resolved: [ResolvedRecord], fileManager: FileManager) throws -> Data {
        var payload = Data()
        func part(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
            payload.append(data)
        }
        part(Data("restore-confirmation-v1".utf8))
        part(Data(receipt.projectID.uuidString.utf8)); part(Data(receipt.id.uuidString.utf8))
        for item in resolved.sorted(by: { $0.record.bundleID + "/" + $0.record.relativePath < $1.record.bundleID + "/" + $1.record.relativePath }) {
            part(Data(item.record.bundleID.utf8)); part(Data(item.record.relativePath.utf8))
            part(item.record.containerFingerprint)
            let exists = try targetExists(item.target, fileManager: fileManager)
            part(Data([exists ? 1 : 0]))
            if exists { part(try digestFile(item.target)) }
        }
        try targetFilesystem?.validateBindings()
        return digest(payload)
    }

    private static func containerFingerprint(_ url: URL) -> Data {
        digest(Data(PatchPathValidator.canonicalFileURL(url).path.utf8))
    }
}

// MARK: - Device Patch Service

// A read-only preparation owns native grants until the entire transaction ends.
// A cancelled/late preparation drops this object and releases every acquired handle.
final class PreparedPatchAccess: @unchecked Sendable {
    let roots: [String: URL]
    let usesWorseQuery: Bool
    private let rootIdentities: [String: String]
    private let lock = NSLock()
    private var handles: [Int64]?
    init(roots: [String: URL], handles: [Int64], usesWorseQuery: Bool) throws {
        rootIdentities = try roots.mapValues { try Self.identity($0.path) }
        self.roots = roots; self.handles = handles; self.usesWorseQuery = usesWorseQuery
    }
    private static func identity(_ path: String) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw PatchPackageError.restoreFailed
        }
        return "\(device):\(inode)"
    }
    func requireRoot(bundleID: String, path: String, worseQuery: Bool) throws {
        lock.lock(); let active = handles != nil; lock.unlock()
        guard active, usesWorseQuery == worseQuery,
              roots[bundleID].map({ PatchPathValidator.canonicalFileURL($0).path }) == path,
              try Self.identity(path) == rootIdentities[bundleID] else {
            throw PatchPackageError.targetAppUnavailable(bundleID)
        }
        if worseQuery {
            // Recheck local metadata under the retained grant, never another
            // potentially blocking native identity query after commit starts.
            let identity = ContainerStore.readWorseQueryIdentity(path)
            guard identity.readable, !identity.diagnostics.contains("identity=conflict"),
                  identity.identifier == nil || identity.identifier == bundleID else {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
        }
    }
    func release() {
        lock.lock(); let values = handles; handles = nil; lock.unlock()
        values?.reversed().forEach { sandbox_extension_release_handle($0) }
    }
    deinit { release() }
}

enum DevicePatchService {
    static func prepareAccess(roots: [String: URL]) async throws -> PreparedPatchAccess {
        try await DirectPatchPreparation.run {
            var handles: [Int64] = []
            var transferred = false
            defer { if !transferred { handles.reversed().forEach { sandbox_extension_release_handle($0) } } }
            let worseQuery = WorseQueryHelper.isAvailable
            for bundleID in roots.keys.sorted() {
                try Task.checkCancellation()
                let path = PatchPathValidator.canonicalFileURL(roots[bundleID]!).path
                guard ContainerStore.isApplicationContainerPath(path) else {
                    throw PatchPackageError.targetAppUnavailable(bundleID)
                }
                if worseQuery {
                    handles.append(try WorseQueryHelper.acquireAccess(for: path))
                    guard ContainerStore.validateWorseQueryTransactionIdentity(path: path, bundleID: bundleID) else {
                        IOS27ContainerSession.invalidate(bundleIDs: [bundleID])
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                } else {
                    guard ExploitSupportPolicy.currentAccessProvider == .legacy3105 else {
                        throw WorseQueryError.appGroupUnavailable
                    }
                    let handle = ContainerStore.grantContainerAccess(path)
                    if handle >= 0 { handles.append(handle) }
                }
                try Task.checkCancellation()
            }
            let access = try PreparedPatchAccess(roots: roots, handles: handles, usesWorseQuery: worseQuery)
            transferred = true
            return access
        }
    }
    static func activeTargetKeys() throws -> Set<String> {
        PatchTransaction.appliedTargetKeys(backupRoot: try PatchProjectLibrary.backupRootURL(), excludingProjectID: nil)
    }
    static func prepareContainers(bundleIDs: [String]) async throws -> [String: URL] {
        try await DirectPatchPreparation.run {
            if ExploitSupportPolicy.currentAccessProvider == .worseQuery {
                try await IOS27ContainerPreparation.shared.prepareAdditionalTargets(bundleIDs: bundleIDs)
            }
            var roots: [String: URL] = [:]
            for bundleID in bundleIDs {
                try Task.checkCancellation()
                let path = try ContainerStore.resolveAppContainerForPatch(bundleID: bundleID)
                guard ContainerStore.isApplicationContainerPath(path) else {
                    throw PatchPackageError.targetAppUnavailable(bundleID)
                }
                roots[bundleID] = URL(fileURLWithPath: path, isDirectory: true)
            }
            return roots
        }
    }

    static func prepareContainers(receipt: PatchTransactionReceipt) async throws -> [String: URL] {
        try await prepareContainers(bundleIDs: PatchTransaction.requiredBundleIdentifiers(for: receipt))
    }

    static func recordedApplicationState(projectID: UUID) -> PatchApplicationState? {
        guard let root = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestRecordedApplicationState(projectID: projectID, backupRoot: root)
    }

    static func inspectExistingApplication(receipt: PatchTransactionReceipt, project: PatchProject,
                                            preparedContainers: [String: URL]? = nil) throws -> PatchApplicationState {
        try withResolvedContainers(bundleIDs: project.allBundleIdentifiers, prepared: preparedContainers) { roots in
            try PatchTransaction.inspectExistingApplication(receipt: receipt, project: project, containerResolver: { bundleID in
                guard let root = roots[bundleID] else { throw PatchPackageError.targetAppUnavailable(bundleID) }
                return root
            })
        }
    }

    static func apply(project: PatchProject, preparedContainers: [String: URL]? = nil,
                      allowOverlappingTargets: Bool = false,
                      preparedAccess: PreparedPatchAccess? = nil) throws -> PatchTransactionReceipt {
        let bundleIDs = orderedBundleIdentifiers(in: project)
        return try withResolvedContainers(bundleIDs: bundleIDs, prepared: preparedContainers, preparedAccess: preparedAccess) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                engine: WorseQueryHelper.isAvailable ? .worseQuery : .legacy3105,
                allowOverlappingTargets: allowOverlappingTargets,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func inspectRestore(receipt: PatchTransactionReceipt, preparedContainers: [String: URL]? = nil) throws -> PatchRestoreInspection {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        return try withResolvedContainers(bundleIDs: bundleIDs, prepared: preparedContainers) { roots in
            try PatchTransaction.inspectRestore(
                receipt: receipt,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowChangedTargets: Bool = false,
        expectedCurrentState: Data? = nil,
        preparedContainers: [String: URL]? = nil,
        preserveLaterPatches: Bool = false,
        preparedAccess: PreparedPatchAccess? = nil
    ) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs, prepared: preparedContainers, preparedAccess: preparedAccess) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                allowChangedTargets: allowChangedTargets,
                expectedCurrentState: expectedCurrentState,
                preserveLaterPatches: preserveLaterPatches,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func resetToAppliedState(
        receipt: PatchTransactionReceipt,
        project: PatchProject
    ) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.resetToAppliedState(
                receipt: receipt,
                fallbackProject: project,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        prepared: [String: URL]? = nil,
        preparedAccess: PreparedPatchAccess? = nil,
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]
        var handles: [Int64] = []
        defer { handles.reversed().forEach { sandbox_extension_release_handle($0) } }

        for bundleID in bundleIDs {
            try DirectPatchExecutionContext.check()
            let path: String
            if let prepared {
                guard let root = prepared[bundleID] else { throw PatchPackageError.targetAppUnavailable(bundleID) }
                path = root.path
            } else {
                path = try ContainerStore.resolveAppContainerForPatch(bundleID: bundleID)
            }
            guard ContainerStore.isApplicationContainerPath(path) else {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            if let preparedAccess {
                let canonical = PatchPathValidator.canonicalFileURL(URL(fileURLWithPath: path, isDirectory: true)).path
                try preparedAccess.requireRoot(bundleID: bundleID, path: canonical, worseQuery: WorseQueryHelper.isAvailable)
            } else if WorseQueryHelper.isAvailable {
                // Throw the actual daemon/token error and hold the grant through
                // backup, writes, verification, rollback and restore.
                handles.append(try WorseQueryHelper.acquireAccess(for: path))
                guard ContainerStore.validateWorseQueryTransactionIdentity(path: path, bundleID: bundleID) else {
                    IOS27ContainerSession.invalidate(bundleIDs: [bundleID])
                    throw PatchPackageError.targetAppUnavailable(bundleID)
                }
            } else {
                guard ExploitSupportPolicy.currentAccessProvider == .legacy3105 else {
                    throw WorseQueryError.appGroupUnavailable
                }
                let handle = ContainerStore.grantContainerAccess(path)
                if handle >= 0 { handles.append(handle) }
            }
            roots[bundleID] = PatchPathValidator.canonicalFileURL(URL(fileURLWithPath: path, isDirectory: true))
        }
        return try operation(roots)
    }
}
