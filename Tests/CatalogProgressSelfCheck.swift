import Foundation

enum FeaturePatchError: Error { case operationInProgress }
enum PatchEngineStateError: Error { case operationNotHeld }
struct PatchOperationError: Error { let underlying: Error }
// ACTUAL_GATE
// ACTUAL_PROGRESS

actor WorkerBoundary {
    private var suspended: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        await withCheckedContinuation { continuation in
            suspended = continuation
            entered = true
        }
    }
    func release() { suspended?.resume(); suspended = nil }
}

@MainActor final class FeaturePatchService {
    var patchOperation: FeaturePatchOperationProgress? {
        didSet { if let patchOperation { observedStages.append(patchOperation.stage) } }
    }
    private var cancelCatalogOperation: (() -> Void)?
    private var catalogOperationCancellation: FeaturePatchOperationCancellation?
    private var pendingPatchOperations = 0
    var patchOperationInProgress = false
    var recoveryRefreshes = 0
    var observedStages: [FeaturePatchOperationProgress.Stage] = []
    func refreshRecoveryItems() { recoveryRefreshes += 1 }
    // ACTUAL_METHODS
    func perform<T>(identity: String, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCatalogOperation(identity: identity, operation: operation)
    }
    func stage(_ value: FeaturePatchOperationProgress.Stage) { updatePatchOperation(value) }
    func commit(_ value: FeaturePatchOperationProgress.Stage) throws { try beginPatchCommit(value) }
    var workerCount: Int { pendingPatchOperations }
}

@main struct CatalogProgressSelfCheck {
    enum Failure: Error { case check(String), expected }
    @MainActor static func main() async throws {
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure.check(message) }
            checks += 1
        }
        func waitFor(_ predicate: @MainActor () async -> Bool) async throws {
            for _ in 0..<2000 {
                if await predicate() { return }
                await Task.yield()
            }
            throw Failure.check("Worker failed to reach its controlled boundary")
        }

        // A queued caller cancellation cannot race through the actual gate.
        do {
            let service = FeaturePatchService(), held = try await PatchFilesystemGate.shared.acquire()
            var touched = false
            let caller = Task { @MainActor in
                try await service.perform(identity: "patch:queued") {
                    try await withExclusivePatchOperation { _ in
                        try Task.checkCancellation()
                        touched = true
                    }
                }
            }
            try await waitFor { service.patchOperation != nil }
            try require(service.patchOperation?.stage == .waiting && service.patchOperation?.canCancel == true,
                        "Waiting progress is real and cancellable while gate is held")
            caller.cancel()
            await PatchFilesystemGate.shared.release(held)
            do { try await caller.value; throw Failure.check("Queued cancellation executed") }
            catch is CancellationError { }
            try require(!touched, "Canceled queued work reached the operation")
            try require(service.patchOperation == nil && !service.patchOperationInProgress && service.workerCount == 0,
                        "Worker completion did not release service progress")
        }

        // UI cancellation is a request; non-cooperative preparation owns busy
        // state until it really returns, never merely until the card disappears.
        do {
            let service = FeaturePatchService(), boundary = WorkerBoundary()
            var callerFinished = false
            let caller = Task { @MainActor in
                defer { callerFinished = true }
                try await service.perform(identity: "patch:download") {
                    service.stage(.download)
                    await boundary.wait()
                    try Task.checkCancellation()
                }
            }
            try await waitFor { await boundary.entered }
            service.cancelPatchOperation(identity: "patch:other", operationID: service.patchOperation!.id)
            try require(service.patchOperation?.cancellationPending == false, "Another card canceled this worker")
            caller.cancel()
            try await waitFor { service.patchOperation?.cancellationPending == true }
            try require(service.patchOperationInProgress && service.workerCount == 1 && !callerFinished,
                        "Caller cancellation prematurely cleared a live underlying worker")
            try require(service.patchOperation?.message.contains("Đang dừng") == true && service.patchOperation?.canCancel == false,
                        "Pending cancellation must describe waiting for actual completion")
            do {
                _ = try await service.perform(identity: "patch:second") { 1 }
                throw Failure.check("Second worker was admitted during cancellation drain")
            } catch FeaturePatchError.operationInProgress { }
            await boundary.release()
            do { try await caller.value; throw Failure.check("Canceled worker returned success") }
            catch is CancellationError { }
            try require(callerFinished && service.patchOperation == nil && !service.patchOperationInProgress,
                        "Actual worker completion failed to release service state")
        }

        // Once commit is reserved, neither view cancellation nor cancel buttons
        // interrupt the underlying write. Re-preparation after restore does not
        // reopen the cancellation window inside the same operation.
        for commitStage in [FeaturePatchOperationProgress.Stage.write, .restore] {
            let service = FeaturePatchService(), boundary = WorkerBoundary(), reprepare = WorkerBoundary()
            let caller = Task { @MainActor in
                try await service.perform(identity: "patch:commit") {
                    service.stage(.target)
                    service.stage(.access)
                    try service.commit(commitStage)
                    await boundary.wait()
                    try Task.checkCancellation()
                    service.stage(.target)
                    await reprepare.wait()
                    try Task.checkCancellation()
                    return 7
                }
            }
            try await waitFor { await boundary.entered }
            try require(service.patchOperation?.stage == commitStage && service.patchOperation?.canCancel == false,
                        "Committed work exposed a cancellation action")
            caller.cancel()
            service.cancelPatchOperation(identity: "patch:commit", operationID: service.patchOperation!.id)
            for _ in 0..<10 { await Task.yield() }
            try require(service.patchOperation?.cancellationPending == false && service.patchOperationInProgress,
                        "Cancellation reached a worker after write/restore commit reservation")
            await boundary.release()
            try await waitFor { await reprepare.entered }
            try require(service.patchOperation?.stage == .target && service.patchOperation?.canCancel == false,
                        "Preparation after a commit re-opened cancellation")
            service.cancelPatchOperation(identity: "patch:commit", operationID: service.patchOperation!.id)
            try require(service.patchOperation?.cancellationPending == false,
                        "A later stage cleared the sticky commit reservation")
            await reprepare.release()
            try require(try await caller.value == 7, "Committed worker did not finish normally")
            try require(service.observedStages.contains(commitStage) && service.patchOperation == nil,
                        "Commit stage was not published/retained until worker completion")
        }

        // A cancellation arriving before atomic commit reservation wins: the
        // write callback must not run even if preparation ignored cancellation.
        do {
            let service = FeaturePatchService(), boundary = WorkerBoundary()
            var committed = false
            let caller = Task { @MainActor in
                try await service.perform(identity: "patch:precommit") {
                    service.stage(.decode)
                    await boundary.wait()
                    try service.commit(.write)
                    committed = true
                }
            }
            try await waitFor { await boundary.entered }
            service.cancelPatchOperation(identity: "patch:precommit", operationID: service.patchOperation!.id)
            await boundary.release()
            do { try await caller.value; throw Failure.check("Canceled preparation entered commit") }
            catch is CancellationError { }
            try require(!committed && service.patchOperation == nil, "Precommit cancellation did not prevent the write")
        }

        // Completion/failure clear the old worker only once; a late cancellation
        // for the old caller cannot cancel a later operation with another ID.
        do {
            let service = FeaturePatchService()
            var firstOperationID: UUID?
            let first = Task { @MainActor in
                try await service.perform(identity: "patch:shared") {
                    firstOperationID = service.patchOperation?.id
                    return 1
                }
            }
            try require(try await first.value == 1 && service.recoveryRefreshes == 1, "Successful worker cleanup count changed")
            let boundary = WorkerBoundary()
            let second = Task { @MainActor in
                try await service.perform(identity: "patch:shared") {
                    service.stage(.access)
                    await boundary.wait()
                    try Task.checkCancellation()
                    throw Failure.expected
                }
            }
            try await waitFor { await boundary.entered }
            first.cancel()
            service.cancelPatchOperation(identity: "patch:shared", operationID: firstOperationID!)
            try require(service.patchOperation?.identity == "patch:shared" && service.patchOperation?.cancellationPending == false,
                        "Old same-card cancellation canceled the later service worker")
            await boundary.release()
            do { _ = try await second.value; throw Failure.check("Expected worker error disappeared") }
            catch Failure.expected { }
            try require(service.patchOperation == nil && !service.patchOperationInProgress && service.recoveryRefreshes == 2,
                        "Failed worker did not clean its own lifecycle once")
        }

        for error: Error in [CancellationError(), URLError(.cancelled), PatchOperationError(underlying: URLError(.cancelled)),
                              PatchOperationError(underlying: PatchOperationError(underlying: CancellationError()))] {
            try require(FeaturePatchService.isPatchOperationCancellation(error), "Canceled I/O was treated as a false OFF failure")
        }
        try require(!FeaturePatchService.isPatchOperationCancellation(URLError(.timedOut)), "A real transport failure was hidden as cancel")
        try require(!FeaturePatchService.isPatchOperationCancellation(Failure.expected), "A real operation failure was hidden as cancel")

        let handle = FeaturePatchOperationCancellation()
        try require(handle.request(), "Early cancellation before worker installation was lost")
        var cancellationDelivered = false
        handle.install { cancellationDelivered = true }
        try require(cancellationDelivered && !handle.request(), "Early cancellation was not delivered exactly once")
        do { try handle.beginCommit(); throw Failure.check("Early cancellation lost commit race") }
        catch is CancellationError { }
        handle.finish()

        print("[PASS] Actual catalog progress, retained worker and commit-safe cancellation: \(checks) checks")
    }
}
