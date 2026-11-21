import Foundation

enum FeaturePatchError: Error { case notAuthenticated, operationInProgress }
enum PatchEngineStateError: Error { case operationNotHeld }
enum PatchRestoreError: Error { case confirmationExpired }
struct PatchItem { let downloadIdentity = "fixture" }
struct PatchRestoreConfirmation { let authRevision: UInt64 = 1 }
struct PatchOperationError: Error { let underlying: Error }

@MainActor final class AuthManager {
    enum State { case verified, idle }
    var authState: State = .verified
    var revision: UInt64 = 1
    var revisionReads = 0
    var authenticationRevision: UInt64 {
        revisionReads += 1
        return revision
    }
}

// ACTUAL_GATE
// ACTUAL_PROGRESS

@MainActor final class FeaturePatchService {
    var applied = 0
    var restored = 0
    var patchOperation: FeaturePatchOperationProgress?
    private var cancelCatalogOperation: (() -> Void)?
    private var catalogOperationCancellation: FeaturePatchOperationCancellation?
    // ACTUAL_LIFECYCLE
    // ACTUAL_APPLY_ENTRY
    // ACTUAL_RESTORE_ENTRY
    // ACTUAL_SESSION_GATE
    private func beginPatchOperation() {}
    private func endPatchOperation() {}
    private func patchStorageSlug(_ patch: PatchItem) -> String { "fixture" }
    private func setRequestedEnabled(_ value: Bool, identity: String) {}
    private func requirePatchEnableAllowed(_ patch: PatchItem,
                                           confirmation: PatchRestoreConfirmation? = nil) throws {}
    private func applyPatchInOperation(_ patch: PatchItem, auth: AuthManager, operationID: UUID,
                                       expectedRevision: UInt64,
                                       recoveryConfirmation: PatchRestoreConfirmation? = nil) async throws {
        try await PatchFilesystemGate.shared.validate(operationID)
        applied += 1
    }
    private func restorePatchInOperation(_ patch: PatchItem, auth: AuthManager, operationID: UUID,
                                         expectedRevision: UInt64,
                                         confirmation: PatchRestoreConfirmation? = nil) async throws {
        try await PatchFilesystemGate.shared.validate(operationID)
        restored += 1
    }
}

@main struct CatalogOperationIntentSelfCheck {
    enum Failure: Error { case check(String) }
    @MainActor static func main() async throws {
        var checks = 0
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure.check(message) }
            checks += 1
        }
        for restoring in [false, true] {
            for change in ["same-session", "new-session", "logout", "cancel"] {
                let auth = AuthManager(), service = FeaturePatchService()
                let held = try await PatchFilesystemGate.shared.acquire()
                let request = Task { @MainActor in
                    if restoring { try await service.restorePatch(PatchItem(), auth: auth) }
                    else { try await service.applyPatch(PatchItem(), auth: auth) }
                }
                // Yield until the production entry captures the caller session.
                for _ in 0..<1000 {
                    if auth.revisionReads > 0 { break }
                    await Task.yield()
                }
                try require(auth.revisionReads > 0, "Entry must bind the request before waiting for the gate")
                if change == "new-session" { auth.revision += 1 }
                if change == "logout" { auth.authState = .idle }
                if change == "cancel" { request.cancel() }
                await PatchFilesystemGate.shared.release(held)
                do {
                    try await request.value
                    try require(change == "same-session", "Stale queued request ran: \(change)")
                } catch FeaturePatchError.notAuthenticated {
                    try require(change == "new-session" || change == "logout", "Unexpected authentication rejection")
                } catch is CancellationError {
                    try require(change == "cancel", "Unexpected cancellation")
                }
                let calls = service.applied + service.restored
                try require(calls == (change == "same-session" ? 1 : 0), "Stale intent reached the filesystem operation")
                let next = try await PatchFilesystemGate.shared.acquire()
                try await PatchFilesystemGate.shared.validate(next)
                await PatchFilesystemGate.shared.release(next)
                try require(true, "The shared gate remains usable after the request")
            }
            let auth = AuthManager(), service = FeaturePatchService()
            auth.authState = .idle
            do {
                if restoring { try await service.restorePatch(PatchItem(), auth: auth) }
                else { try await service.applyPatch(PatchItem(), auth: auth) }
                throw Failure.check("Unauthenticated intent accepted")
            } catch FeaturePatchError.notAuthenticated {
                try require(service.applied + service.restored == 0, "Unauthenticated request reached I/O")
            }
        }
        print("[PASS] Catalog apply/restore queued session intent: \(checks) checks")
    }
}
