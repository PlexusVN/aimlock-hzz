import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum FilesystemCheckError: Error { case failed(String), injected }

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}

enum ContainerStore {
    static func isApplicationContainerPath(_ path: String) -> Bool { false }
}

@main struct DirectFilesystemRecoverySelfCheck {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw FilesystemCheckError.failed(message) }
        checks += 1
    }
    static func expectFailure(_ message: String, operation: () throws -> Void) throws {
        do { try operation() } catch { checks += 1; return }
        throw FilesystemCheckError.failed(message)
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("aimlock-direct-audit-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func fixture(_ name: String) throws -> (URL, URL) {
            let root = base.appendingPathComponent(name), game = root.appendingPathComponent("game")
            try fm.createDirectory(at: game.appendingPathComponent("Documents"), withIntermediateDirectories: true)
            return (game, root.appendingPathComponent("backups"))
        }
        func project(_ names: [String], id: UUID = UUID()) -> PatchProject {
            PatchProject(id: id, name: "fixture", rules: names.enumerated().map { index, name in
                PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/" + name,
                          replacementFilename: name, replacementData: Data(repeating: UInt8(index + 90), count: index == 0 ? 0 : (index == 1 ? 512 : 8192)))
            })
        }
        let original = Data(repeating: 7, count: 4096)
        // Empty/shorter/longer replacement bytes must not retain a stale suffix.
        do {
            let (game, backup) = try fixture("lengths")
            let patch = project(["a", "b", "c"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game }, beforeWrite: { index in
                if index == 0 {
                    let receipt = PatchTransaction.latestReceipt(projectID: patch.id, backupRoot: backup)!
                    let originals = try fm.contentsOfDirectory(at: receipt.journalURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "original" }
                    try check(originals.count == patch.rules.count, "all originals are backed up before the first forward write")
                    try check(try PatchTransaction.recordedApplicationState(receipt: receipt) == .recoveryRequired, "prepared journal exists before the first forward write")
                }
            })
            for rule in patch.rules { try check(try Data(contentsOf: game.appendingPathComponent(rule.relativePath)) == rule.replacementData, "replacement bytes/length") }
            try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game })
            for rule in patch.rules { try check(try Data(contentsOf: game.appendingPathComponent(rule.relativePath)) == original, "restored exact original bytes") }
        }
        // Failure halfway through apply restores existing data and removes new files/directories.
        do {
            let (game, backup) = try fixture("partial")
            let patch = project(["a", "created", "later"])
            try original.write(to: game.appendingPathComponent("Documents/a"))
            try expectFailure("injected apply failure must escape") {
                _ = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game }, beforeWrite: { if $0 == 2 { throw FilesystemCheckError.injected } })
            }
            try check(try Data(contentsOf: game.appendingPathComponent("Documents/a")) == original, "partial apply restores existing bytes")
            try check(!fm.fileExists(atPath: game.appendingPathComponent("Documents/created").path), "partial apply removes newly introduced file")
            try check(try PatchEngineApplicationStore(backupRoot: backup).read(patch.id)?.phase == .restored, "successful rollback records OFF durably")
        }
        // A failed restore must put every target back into its pre-restore state.
        do {
            let (game, backup) = try fixture("restore-failure")
            let patch = project(["a", "b"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try expectFailure("restore fault must escape") {
                try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game }, beforeWrite: { if $0 == 1 { throw FilesystemCheckError.injected } })
            }
            for rule in patch.rules { try check(try Data(contentsOf: game.appendingPathComponent(rule.relativePath)) == rule.replacementData, "failed restore returns to pre-restore bytes") }
            try check(try PatchTransaction.recordedApplicationState(receipt: receipt) == .applied, "failed restore retains active journal")
            try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game })
        }
        // A damaged original backup must never be used to overwrite current data.
        do {
            let (game, backup) = try fixture("backup-corrupt")
            let patch = project(["a"])
            let target = game.appendingPathComponent("Documents/a")
            try original.write(to: target)
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            let originals = try fm.contentsOfDirectory(at: receipt.journalURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "original" }
            try Data([99]).write(to: originals[0])
            try expectFailure("corrupted original backup must block restore") { try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game }) }
            try check(try Data(contentsOf: target) == patch.rules[0].replacementData, "corrupt backup failure leaves current target intact")
        }
        do {
            let (game, backup) = try fixture("backup-missing")
            let patch = project(["a"]), target = game.appendingPathComponent("Documents/a")
            try original.write(to: target)
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            let originalURL = try fm.contentsOfDirectory(at: receipt.journalURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).first { $0.pathExtension == "original" }!
            try fm.removeItem(at: originalURL)
            try expectFailure("missing original backup must block restore") { try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game }) }
            try check(try Data(contentsOf: target) == patch.rules[0].replacementData, "missing backup leaves current target intact")
        }
        // Reconstruct a prepared journal left by interruption before commit.
        do {
            let (game, backup) = try fixture("prepared-restart")
            let patch = project(["a", "b"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            var journal = try PropertyListSerialization.propertyList(from: Data(contentsOf: receipt.journalURL), format: nil) as! [String: Any]
            journal["status"] = "prepared"
            try PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0).write(to: receipt.journalURL, options: .atomic)
            try original.write(to: game.appendingPathComponent(patch.rules[1].relativePath))
            try check(PatchTransaction.latestRecordedApplicationState(projectID: patch.id, backupRoot: backup) == .recoveryRequired, "prepared restart is never reported as OFF")
            let reconstructed = PatchTransaction.latestReceipt(projectID: patch.id, backupRoot: backup)!
            try PatchTransaction.restore(receipt: reconstructed, containerResolver: { _ in game })
            for rule in patch.rules { try check(try Data(contentsOf: game.appendingPathComponent(rule.relativePath)) == original, "prepared-journal recovery restores every baseline") }
        }
        // Changes made by the game or container replacement are never silently overwritten.
        do {
            let (game, backup) = try fixture("changed-target")
            let patch = project(["a"]), target = game.appendingPathComponent("Documents/a")
            try original.write(to: target)
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            let changed = Data("new game data".utf8)
            try changed.write(to: target)
            try check(try PatchTransaction.inspectRestore(receipt: receipt, containerResolver: { _ in game }).changedTargets.count == 1, "game edit appears in restore inspection")
            try expectFailure("changed target must require explicit confirmation") { try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game }) }
            try check(try Data(contentsOf: target) == changed, "unconfirmed restore preserves game edit")
            let other = game.deletingLastPathComponent().appendingPathComponent("reinstalled-game")
            try fm.createDirectory(at: other, withIntermediateDirectories: true)
            try expectFailure("old journal must not target another container") { try PatchTransaction.restore(receipt: receipt, allowChangedTargets: true, containerResolver: { _ in other }) }
            try PatchTransaction.restore(receipt: receipt, allowChangedTargets: true, containerResolver: { _ in game })
            try check(try Data(contentsOf: target) == original, "confirmed changed-target restore recovers captured baseline")
        }
        // Parent directories created by a patch are removed only when still empty.
        do {
            let (game, backup) = try fixture("directories")
            let patch = PatchProject(name: "new-parent", rules: [PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/new/deep/file", replacementFilename: "file", replacementData: Data([3]))])
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try check(fm.fileExists(atPath: game.appendingPathComponent("Documents/new/deep/file").path), "apply creates missing parents and file")
            try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game })
            try check(!fm.fileExists(atPath: game.appendingPathComponent("Documents/new").path), "restore removes empty patch-created parents")
        }
        // Link traversal outside the resolved container is rejected before backup/write.
        do {
            let (game, backup) = try fixture("symlink")
            let external = game.deletingLastPathComponent().appendingPathComponent("external")
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            try original.write(to: external.appendingPathComponent("a"))
            try fm.createSymbolicLink(at: game.appendingPathComponent("Documents/alias"), withDestinationURL: external)
            let patch = PatchProject(name: "link", rules: [PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/alias/a", replacementFilename: "a", replacementData: Data([4]))])
            try expectFailure("parent symlink must not escape container") { _ = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game }) }
            try check(try Data(contentsOf: external.appendingPathComponent("a")) == original, "external link target remains intact")
            let traversal = PatchProject(name: "traversal", rules: [PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/../../external/a", replacementFilename: "a", replacementData: Data([4]))])
            try expectFailure("relative traversal must not leave container") { _ = try PatchTransaction.apply(project: traversal, backupRoot: backup, containerResolver: { _ in game }) }
            try check(try Data(contentsOf: external.appendingPathComponent("a")) == original, "traversal preserves outside bytes")
        }
        // Distinct targets may be applied together, but the same file cannot be owned twice.
        do {
            let (game, backup) = try fixture("overlap")
            let first = project(["a"]), independent = project(["b"]), overlap = project(["a"])
            try original.write(to: game.appendingPathComponent("Documents/a"))
            try original.write(to: game.appendingPathComponent("Documents/b"))
            _ = try PatchTransaction.apply(project: first, backupRoot: backup, containerResolver: { _ in game })
            _ = try PatchTransaction.apply(project: independent, backupRoot: backup, containerResolver: { _ in game })
            try expectFailure("two projects cannot own the same target") { _ = try PatchTransaction.apply(project: overlap, backupRoot: backup, containerResolver: { _ in game }) }
        }
        // Damaged journal and surviving direct provenance cannot establish a new baseline.
        for reuseID in [true, false] {
            let (game, backup) = try fixture("journal-corrupt-\(reuseID)")
            let patch = project(["a"])
            let target = game.appendingPathComponent("Documents/a")
            try original.write(to: target)
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try Data("corrupt journal".utf8).write(to: receipt.journalURL)
            try check(PatchTransaction.latestRecordedApplicationState(projectID: patch.id, backupRoot: backup) == .recoveryRequired, "corrupt journal is recovery-required rather than OFF")
            let next = project(["a"], id: reuseID ? patch.id : UUID())
            try expectFailure("corrupt active journal permits a misleading baseline (reuse=\(reuseID))") {
                _ = try PatchTransaction.apply(project: next, backupRoot: backup, containerResolver: { _ in game })
            }
            try check(try Data(contentsOf: target) == patch.rules[0].replacementData, "damaged history is retained without mutation")
        }
        for reuseID in [true, false] {
            let (game, backup) = try fixture("journal-missing-\(reuseID)")
            let patch = project(["a"]), target = game.appendingPathComponent("Documents/a")
            try original.write(to: target)
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try fm.removeItem(at: receipt.journalURL)
            let next = project(["a"], id: reuseID ? patch.id : UUID())
            try expectFailure("missing active journal must block a new baseline") { _ = try PatchTransaction.apply(project: next, backupRoot: backup, containerResolver: { _ in game }) }
            try check(try Data(contentsOf: target) == patch.rules[0].replacementData, "missing journal retains current target")
        }
        // Revocation between reset writes must cancel forward writes and recover the
        // exact game-edited state, not silently report successful reapplication.
        do {
            let (game, backup) = try fixture("reset-revoked")
            let patch = project(["a", "b", "c"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            let edited = Data("game changed since patch".utf8)
            for rule in patch.rules { try edited.write(to: game.appendingPathComponent(rule.relativePath)) }
            let forwardWrites = WriteCounter()
            do {
                try await DirectPatchExecutor.run(validation: {}, operation: {
                    try PatchTransaction.resetToAppliedState(receipt: receipt, containerResolver: { _ in game }, beforeWrite: { index in
                        forwardWrites.increment()
                        if index == 0 { NotificationCenter.default.post(name: Notification.Name("AstraAuthenticationInvalidated"), object: nil) }
                    })
                })
                throw FilesystemCheckError.failed("reset ignored authentication revocation")
            } catch FilesystemCheckError.failed(let reason) { throw FilesystemCheckError.failed(reason) }
            catch { checks += 1 }
            try check(forwardWrites.value == 1, "reset stops before next file after revocation")
            for rule in patch.rules { try check(try Data(contentsOf: game.appendingPathComponent(rule.relativePath)) == edited, "reset revocation restores pre-reset game-edited state") }
        }
        // A scoped container grant does not imply read/list permission on its
        // system-owned ancestors. Do not open each absolute ancestor directory.
        if getuid() != 0 {
            let (initialGame, backup) = try fixture("search-only-ancestor")
            let parent = initialGame.deletingLastPathComponent().appendingPathComponent("search-only")
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let game = parent.appendingPathComponent("game")
            try fm.moveItem(at: initialGame, to: game)
            let patch = project(["a"]), target = game.appendingPathComponent("Documents/a")
            try original.write(to: target)
            guard chmod(parent.path, mode_t(0o111)) == 0 else { throw FilesystemCheckError.failed("set search-only parent") }
            defer { _ = chmod(parent.path, mode_t(0o755)) }
            let denied = open(parent.path, O_RDONLY | O_DIRECTORY)
            if denied >= 0 { close(denied) }
            try check(denied < 0, "fixture denies listing parent while permitting traversal to granted root")
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game })
            try check(try Data(contentsOf: target) == original, "scoped root works without list permission on ancestor")
        }
        // A real failed backup leaves the explicit no-mutation marker. It
        // can be retried; an unmarked legacy orphan with bytes cannot.
        if getuid() != 0 {
            let (game, backup) = try fixture("pre-journal-orphan")
            let patch = project(["a", "b"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let denied = game.appendingPathComponent("Documents/b")
            guard chmod(denied.path, mode_t(0)) == 0 else { throw FilesystemCheckError.failed("deny backup source") }
            defer { _ = chmod(denied.path, mode_t(0o644)) }
            try expectFailure("actual backup denial escapes before mutation") {
                _ = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            }
            let projectDirectory = backup.appendingPathComponent(patch.id.uuidString)
            let draft = try fm.contentsOfDirectory(at: projectDirectory, includingPropertiesForKeys: nil).first!
            try check(fm.fileExists(atPath: draft.appendingPathComponent(".prewrite.plist").path), "failed backup retains durable no-mutation marker")
            try check(!fm.fileExists(atPath: draft.appendingPathComponent("journal.plist").path), "backup failure precedes prepared journal")
            guard chmod(denied.path, mode_t(0o644)) == 0 else { throw FilesystemCheckError.failed("restore backup source permission") }
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try check(!fm.fileExists(atPath: receipt.journalURL.deletingLastPathComponent().appendingPathComponent(".prewrite.plist").path), "mutation cannot start while prewrite marker remains")
            try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game })
            for rule in patch.rules { try check(try Data(contentsOf: game.appendingPathComponent(rule.relativePath)) == original, "genuine prewrite draft does not block retry") }
        }
        for reuseID in [true, false] {
            let (game, backup) = try fixture("all-metadata-missing-\(reuseID)")
            let patch = project(["a"]), target = game.appendingPathComponent("Documents/a")
            try original.write(to: target)
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try fm.removeItem(at: receipt.journalURL)
            try fm.removeItem(at: backup.appendingPathComponent(".engine-applications/" + patch.id.uuidString + ".plist"))
            try check(PatchTransaction.latestRecordedApplicationState(projectID: patch.id, backupRoot: backup) == .recoveryRequired, "unmarked backup-only orphan is unknown even if provenance is lost")
            let next = project(["a"], id: reuseID ? patch.id : UUID())
            try expectFailure("unknown legacy backup-only orphan blocks recapture") {
                _ = try PatchTransaction.apply(project: next, backupRoot: backup, containerResolver: { _ in game })
            }
            try check(try Data(contentsOf: target) == patch.rules[0].replacementData, "metadata loss preserves target and backup evidence")
        }
        do {
            let (game, backup) = try fixture("new-private-file-history-lost")
            var patch = project(["created"])
            patch.isPrivate = true
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try fm.removeItem(at: receipt.journalURL)
            try fm.removeItem(at: backup.appendingPathComponent(".engine-applications/" + patch.id.uuidString + ".plist"))
            let remaining = try fm.contentsOfDirectory(at: receipt.journalURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            try check(remaining.isEmpty, "private new-file transaction can lose both metadata files and leave an empty transaction directory")
            try check(PatchTransaction.latestRecordedApplicationState(projectID: patch.id, backupRoot: backup) == .recoveryRequired, "unfenced empty transaction is unknown rather than OFF")
            try expectFailure("empty legacy transaction must block a misleading new baseline") {
                _ = try PatchTransaction.apply(project: project(["created"]), backupRoot: backup, containerResolver: { _ in game })
            }
            try check(try Data(contentsOf: game.appendingPathComponent("Documents/created")) == patch.rules[0].replacementData, "empty orphan preserves its possibly created target")
        }
        // Confirmation is bound to exact bytes and the receipt. A second game
        // edit while the dialog is open must require another inspection.
        do {
            let (game, backup) = try fixture("confirmation")
            let patch = project(["a"]), target = game.appendingPathComponent("Documents/a")
            try original.write(to: target)
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try Data("first game edit".utf8).write(to: target)
            let inspection = try PatchTransaction.inspectRestore(receipt: receipt, containerResolver: { _ in game })
            try check(inspection.currentStateSnapshot != nil && inspection.changedTargets.count == 1, "inspection returns receipt-bound current-state snapshot")
            let later = Data("second game edit".utf8)
            try later.write(to: target)
            try expectFailure("stale confirmation must not authorize newer game bytes") {
                try PatchTransaction.restore(receipt: receipt, allowChangedTargets: true,
                    expectedCurrentState: inspection.currentStateSnapshot, containerResolver: { _ in game })
            }
            try check(try Data(contentsOf: target) == later, "stale confirmation leaves latest game edit intact")
            let fresh = try PatchTransaction.inspectRestore(receipt: receipt, containerResolver: { _ in game })
            try check(fresh.currentStateSnapshot != inspection.currentStateSnapshot, "changed bytes produce a different confirmation")
            try PatchTransaction.restore(receipt: receipt, allowChangedTargets: true,
                expectedCurrentState: fresh.currentStateSnapshot, containerResolver: { _ in game })
            try check(try Data(contentsOf: target) == original, "fresh explicit confirmation restores exact baseline")
        }
        // The path can change after validation. Pinned directory descriptors
        // prevent writes, readback and rollback from following a replacement link.
        for operation in ["apply", "restore", "reset"] {
            let (game, backup) = try fixture("parent-race-" + operation)
            let patch = project(["a", "b"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let receipt = operation == "apply" ? nil : try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            let outside = game.deletingLastPathComponent().appendingPathComponent("outside")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let outsideBytes = Data("outside must not change".utf8)
            for name in ["a", "b"] { try outsideBytes.write(to: outside.appendingPathComponent(name)) }
            let directory = game.appendingPathComponent("Documents"), moved = game.appendingPathComponent("previous")
            let swap: (Int) throws -> Void = { index in
                if index == 1 {
                    try fm.moveItem(at: directory, to: moved)
                    try fm.createSymbolicLink(at: directory, withDestinationURL: outside)
                }
            }
            try expectFailure("changed target parent must not report successful " + operation) {
                if operation == "apply" {
                    _ = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game }, beforeWrite: swap)
                } else if operation == "restore" {
                    try PatchTransaction.restore(receipt: receipt!, containerResolver: { _ in game }, beforeWrite: swap)
                } else {
                    try PatchTransaction.resetToAppliedState(receipt: receipt!, containerResolver: { _ in game }, beforeWrite: swap)
                }
            }
            for (index, name) in ["a", "b"].enumerated() {
                try check(try Data(contentsOf: outside.appendingPathComponent(name)) == outsideBytes, "\(operation) never follows swapped parent to outside bytes")
                let expected = operation == "apply" ? original : patch.rules[index].replacementData
                try check(try Data(contentsOf: moved.appendingPathComponent(name)) == expected, "\(operation) rollback uses pinned original parent")
            }
            try check(fm.fileExists(atPath: backup.path), "\(operation) race retains transaction evidence")
        }
        // Rollback may rewrite only targets for which this transaction began a
        // mutation. A later external edit to an untouched file must survive.
        do {
            let (game, backup) = try fixture("external-edit-before-apply-failure")
            let patch = project(["a", "b"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let later = Data("new external data after backup".utf8)
            try expectFailure("external edit plus later apply failure escapes") {
                _ = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game }, beforeWrite: { index in
                    if index == 1 {
                        try later.write(to: game.appendingPathComponent("Documents/b"))
                        throw FilesystemCheckError.injected
                    }
                })
            }
            try check(try Data(contentsOf: game.appendingPathComponent("Documents/a")) == original, "rollback recovers only the file this apply mutated")
            try check(try Data(contentsOf: game.appendingPathComponent("Documents/b")) == later, "apply rollback preserves unrelated newer edit to untouched file")
        }
        do {
            let (game, backup) = try fixture("external-edit-during-restore")
            let patch = project(["a", "b"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            let inspection = try PatchTransaction.inspectRestore(receipt: receipt, containerResolver: { _ in game })
            let later = Data("new external data while restore runs".utf8)
            try expectFailure("later target changed after confirmation must abort restore") {
                try PatchTransaction.restore(receipt: receipt, expectedCurrentState: inspection.currentStateSnapshot, containerResolver: { _ in game }, beforeWrite: { index in
                    if index == 1 { try later.write(to: game.appendingPathComponent("Documents/a")) }
                })
            }
            try check(try Data(contentsOf: game.appendingPathComponent("Documents/a")) == later, "restore rollback preserves external edit to unmodified target")
            try check(try Data(contentsOf: game.appendingPathComponent("Documents/b")) == patch.rules[1].replacementData, "restore rollback recovers its earlier target")
            try check(try PatchTransaction.recordedApplicationState(receipt: receipt) == .applied, "failed stale restore retains active recovery journal")
        }
        // Prepared recovery can safely recognize original/replacement bytes,
        // but cannot silently overwrite a third state written by the game.
        do {
            let (game, backup) = try fixture("prepared-third-state")
            let patch = project(["a", "b", "new"])
            for rule in patch.rules.prefix(2) { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            var journal = try PropertyListSerialization.propertyList(from: Data(contentsOf: receipt.journalURL), format: nil) as! [String: Any]
            journal["status"] = "prepared"
            try PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0).write(to: receipt.journalURL, options: .atomic)
            try original.write(to: game.appendingPathComponent("Documents/a"))
            let changed = Data("game third state after interruption".utf8)
            let target = game.appendingPathComponent("Documents/b")
            try changed.write(to: target)
            try fm.removeItem(at: game.appendingPathComponent("Documents/new"))
            let inspection = try PatchTransaction.inspectRestore(receipt: receipt, containerResolver: { _ in game })
            try check(inspection.changedTargets.map(\.relativePath) == ["Documents/b"], "prepared recovery recognizes original/replacement/missing-new and flags only third-state bytes")
            try expectFailure("prepared third-state edit must require confirmation") {
                try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game })
            }
            try check(try Data(contentsOf: target) == changed, "prepared default restore preserves game third-state bytes")
            let later = Data("a newer edit while confirmation is open".utf8)
            try later.write(to: target)
            try expectFailure("prepared recovery confirmation also rejects newer edits") {
                try PatchTransaction.restore(receipt: receipt, allowChangedTargets: true,
                    expectedCurrentState: inspection.currentStateSnapshot, containerResolver: { _ in game })
            }
            try check(try Data(contentsOf: target) == later, "prepared stale dialog preserves current data")
            let fresh = try PatchTransaction.inspectRestore(receipt: receipt, containerResolver: { _ in game })
            try PatchTransaction.restore(receipt: receipt, allowChangedTargets: true,
                expectedCurrentState: fresh.currentStateSnapshot, containerResolver: { _ in game })
            try check(try Data(contentsOf: target) == original, "confirmed prepared recovery restores known original")
        }
        // A directory which another process creates after the backup snapshot
        // must not be adopted into our ownership or deleted during rollback.
        do {
            let (game, backup) = try fixture("planned-directory-already-created")
            let directory = game.appendingPathComponent("Documents/new")
            let patch = PatchProject(name: "directory-race", rules: [PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/new/file", replacementFilename: "file", replacementData: Data([4]))])
            try expectFailure("planned missing directory appearing before mkdir must abort") {
                _ = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game }, beforeDirectoryCreate: { _ in
                    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                })
            }
            try check(fm.fileExists(atPath: directory.path), "rollback preserves directory created by another process")
            try check(!fm.fileExists(atPath: directory.appendingPathComponent("file").path), "ownership conflict precedes file mutation")
        }
        // An owned name replaced by an external empty directory is not the
        // original inode, even though its path is still identical.
        do {
            let (game, backup) = try fixture("created-directory-replaced")
            let directory = game.appendingPathComponent("Documents/new"), moved = game.appendingPathComponent("Documents/our-previous-directory")
            let patch = PatchProject(name: "replace-created", rules: [PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/new/file", replacementFilename: "file", replacementData: Data([5]))])
            try expectFailure("replaced owned directory must not be cleaned up as ours") {
                _ = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game }, beforeWrite: { _ in
                    try fm.moveItem(at: directory, to: moved)
                    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                    throw FilesystemCheckError.injected
                })
            }
            try check(fm.fileExists(atPath: directory.path), "rollback preserves external replacement empty directory")
            try check(fm.fileExists(atPath: moved.path), "uncertain moved original directory remains available")
        }
        // Old or interrupted journals lacking persisted directory identity may
        // restore file bytes, but never guess ownership of an empty directory.
        do {
            let (game, backup) = try fixture("directory-identity-not-persisted")
            let directory = game.appendingPathComponent("Documents/new")
            let patch = PatchProject(name: "legacy-directory", rules: [PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/new/file", replacementFilename: "file", replacementData: Data([6]))])
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            var journal = try PropertyListSerialization.propertyList(from: Data(contentsOf: receipt.journalURL), format: nil) as! [String: Any]
            var directories = journal["createdDirectories"] as! [[String: Any]]
            try check(directories.allSatisfy { $0["device"] != nil && $0["inode"] != nil }, "created directory ownership identities persist before file mutation")
            for index in directories.indices {
                directories[index].removeValue(forKey: "device")
                directories[index].removeValue(forKey: "inode")
            }
            journal["createdDirectories"] = directories
            journal["status"] = "prepared"
            try PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0).write(to: receipt.journalURL, options: .atomic)
            try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game })
            try check(!fm.fileExists(atPath: directory.appendingPathComponent("file").path), "unknown directory ownership does not block exact new-file recovery")
            try check(fm.fileExists(atPath: directory.path), "legacy or unpersisted ownership preserves empty directory")
        }
        // Re-enabling a directory-only or mixed project must verify the same
        // declared directory set and the actual directory type/existence.
        do {
            let (game, backup) = try fixture("directory-only-reenable")
            let target = game.appendingPathComponent("Documents/effect")
            let patch = PatchProject(name: "directory-only", directories: [PatchDirectory(bundleID: "com.fixture.game", relativePath: "Documents/effect")], rules: [])
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try check(try PatchTransaction.inspectExistingApplication(receipt: receipt, project: patch, containerResolver: { _ in game }) == .applied, "existing directory-only application is verified")
            var revised = patch
            revised.directories = [PatchDirectory(bundleID: "com.fixture.game", relativePath: "Documents/other")]
            try check(try PatchTransaction.inspectExistingApplication(receipt: receipt, project: revised, containerResolver: { _ in game }) == .recoveryRequired, "same ID with changed directory targets cannot adopt old receipt")
            revised.directories = []
            try check(try PatchTransaction.inspectExistingApplication(receipt: receipt, project: revised, containerResolver: { _ in game }) == .recoveryRequired, "removed directory declaration cannot silently adopt old receipt")
            try fm.removeItem(at: target)
            try check(try PatchTransaction.inspectExistingApplication(receipt: receipt, project: patch, containerResolver: { _ in game }) == .recoveryRequired, "missing required directory is not applied")
            try Data([1]).write(to: target)
            try check(try PatchTransaction.inspectExistingApplication(receipt: receipt, project: patch, containerResolver: { _ in game }) == .recoveryRequired, "file replacing required directory is not applied")
            try fm.removeItem(at: target)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            var legacy = try PropertyListSerialization.propertyList(from: Data(contentsOf: receipt.journalURL), format: nil) as! [String: Any]
            legacy.removeValue(forKey: "declaredDirectories")
            try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0).write(to: receipt.journalURL, options: .atomic)
            try check(try PatchTransaction.inspectExistingApplication(receipt: receipt, project: patch, containerResolver: { _ in game }) == .applied, "legacy journal derives declared directories from bound provenance")
        }
        do {
            let (game, backup) = try fixture("preexisting-directory-reenable")
            let target = game.appendingPathComponent("Documents/existing")
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            let patch = PatchProject(name: "preexisting-directory", directories: [PatchDirectory(bundleID: "com.fixture.game", relativePath: "Documents/existing")], rules: [])
            let receipt = try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game })
            try check(try PatchTransaction.inspectExistingApplication(receipt: receipt, project: patch, containerResolver: { _ in game }) == .applied, "preexisting directory has durable target identity even without createdDirectory record")
            try fm.removeItem(at: target)
            try check(try PatchTransaction.inspectExistingApplication(receipt: receipt, project: patch, containerResolver: { _ in game }) == .recoveryRequired, "missing preexisting directory blocks adoption")
            try PatchTransaction.restore(receipt: receipt, containerResolver: { _ in game })
            try check(PatchTransaction.latestRecordedApplicationState(projectID: patch.id, backupRoot: backup) == .off, "directory-only recovery can terminate without inventing files")
        }
        do {
            let (game, backup) = try fixture("write-deadline")
            let patch = project(["a", "b"])
            for rule in patch.rules { try original.write(to: game.appendingPathComponent(rule.relativePath)) }
            var deadlineFailed = false
            do {
                _ = try await DirectPatchExecutor.run(timeout: 1.0, validation: {}) {
                    try PatchTransaction.apply(project: patch, backupRoot: backup, containerResolver: { _ in game },
                        beforeWrite: { if $0 == 1 { Thread.sleep(forTimeInterval: 1.1) } })
                }
            } catch { deadlineFailed = true }
            try check(deadlineFailed, "expired write returned success")
            for rule in patch.rules {
                try check(try Data(contentsOf: game.appendingPathComponent(rule.relativePath)) == original,
                    "expired write must finish rollback before releasing the caller")
            }
            try check(PatchTransaction.latestRecordedApplicationState(projectID: patch.id, backupRoot: backup) == .off,
                "expired write must leave a durable rolled-back state")
        }
        do {
            let (game, backup) = try fixture("independent-overwrite")
            let file = game.appendingPathComponent("Documents/shared")
            try Data([0]).write(to: file)
            func project(_ byte: UInt8) -> PatchProject {
                PatchProject(name: "Independent", rules: [PatchRule(bundleID: "com.fixture.game",
                    relativePath: "Documents/shared", replacementFilename: "shared", replacementData: Data([byte]))])
            }
            var first = project(1)
            first.rules.append(PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/only-a",
                replacementFilename: "only-a", replacementData: Data([1])))
            let a = try PatchTransaction.apply(project: first, backupRoot: backup,
                allowOverlappingTargets: true, containerResolver: { _ in game })
            let b = try PatchTransaction.apply(project: project(2), backupRoot: backup,
                allowOverlappingTargets: true, containerResolver: { _ in game })
            let suite = "snapshot-fs-" + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            preferences.set(a.projectID.uuidString, forKey: "patch_applied_catalog_1_generic_projectID")
            preferences.set(b.projectID.uuidString, forKey: "patch_applied_catalog_2_generic_projectID")
            let targets = [CatalogPresentationTarget(key: "a", identity: "catalog_1_generic", legacyIdentity: "old_a"),
                           CatalogPresentationTarget(key: "b", identity: "catalog_2_generic", legacyIdentity: "old_b")]
            func snapshot() throws -> CatalogPresentationSnapshot {
                try CatalogPresentationReader.load(root: backup, defaults: preferences, targets: targets, overrides: .init())
            }
            try check(try snapshot().cards.values.allSatisfy(\.enabled), "display snapshot must read actual applied journals")
            try check(try Data(contentsOf: file) == Data([2]), "later feature must overwrite the same file")
            var broken = project(3)
            broken.rules.append(PatchRule(bundleID: "com.fixture.game", relativePath: "Documents/failing",
                replacementFilename: "failing", replacementData: Data([3])))
            try expectFailure("overlap write failure must roll back") {
                _ = try PatchTransaction.apply(project: broken, backupRoot: backup,
                    allowOverlappingTargets: true, containerResolver: { _ in game },
                    beforeWrite: { if $0 == 1 { throw FilesystemCheckError.injected } })
            }
            try check(try Data(contentsOf: file) == Data([2]), "failed overwrite must preserve last successful feature")
            try PatchTransaction.restore(receipt: a, allowChangedTargets: true, preserveLaterPatches: true,
                containerResolver: { _ in game })
            try check(try Data(contentsOf: file) == Data([2]), "turning earlier feature OFF must preserve later writer")
            try check(!fm.fileExists(atPath: game.appendingPathComponent("Documents/only-a").path), "OFF must restore its own non-overlapping targets")
            try check(PatchTransaction.latestRecordedApplicationState(projectID: first.id, backupRoot: backup) == .off, "earlier feature must turn OFF")
            let afterA = try snapshot()
            try check(afterA.cards["a"]?.enabled == false && afterA.cards["b"]?.enabled == true, "display must retain independent toggle states")
            try PatchTransaction.restore(receipt: b, allowChangedTargets: true, preserveLaterPatches: true,
                containerResolver: { _ in game })
            try check(try Data(contentsOf: file) == Data([1]), "OFF restores the latest feature's own pre-activation snapshot")
            try check(try snapshot().cards.values.allSatisfy { !$0.enabled && $0.state == .off }, "display must read actual restored journals")
        }
        print("Direct filesystem recovery: \(checks) checks passed")
    }
}
