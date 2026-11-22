import Foundation

private final class DelayedPreparation: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var began = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return began }
    func run() -> Int {
        lock.lock(); began = true; lock.unlock()
        release.wait()
        return 99
    }
}

@main struct DirectPatchExecutorSelfCheck {
    @MainActor static func main() async throws {
        let value = try await DirectPatchExecutor.run(validation: {}) {
            precondition(!Thread.isMainThread)
            try DirectPatchExecutionContext.check()
            return 42
        }
        precondition(value == 42)
        // A stuck read-only OS lookup must not hold the UI or publish success late.
        let delayed = DelayedPreparation()
        let preparation = Task { try await DirectPatchPreparation.run(timeout: 0.1) { delayed.run() } }
        for _ in 0..<1000 {
            if delayed.started { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(delayed.started, "preparation never started")
        var heartbeat = false
        let pulse = Task { @MainActor in heartbeat = true }
        do { _ = try await preparation.value; preconditionFailure("late preparation succeeded") }
        catch DirectPatchExecutionError.preparationTimedOut {}
        await pulse.value
        precondition(heartbeat, "preparation blocked MainActor")
        do {
            _ = try await DirectPatchPreparation.run { preconditionFailure("retry spawned another stuck native lookup") }
        } catch DirectPatchExecutionError.preparationBusy {}
        delayed.release.signal()
        var reusable = false
        for _ in 0..<1000 {
            do {
                let result = try await DirectPatchPreparation.run { 7 }
                precondition(result == 7); reusable = true; break
            } catch DirectPatchExecutionError.preparationBusy { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        precondition(reusable, "native slot never released after late completion")
        let cancelledPreparation = DelayedPreparation()
        let cancelled = Task { try await DirectPatchPreparation.run { cancelledPreparation.run() } }
        while !cancelledPreparation.started { try await Task.sleep(nanoseconds: 1_000_000) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancelled preparation succeeded") }
        catch is CancellationError {}
        cancelledPreparation.release.signal()
        do {
            _ = try await DirectPatchExecutor.run(timeout: 0.01, validation: {}) {
                Thread.sleep(forTimeInterval: 0.03)
                try DirectPatchExecutionContext.check()
                return true
            }
            preconditionFailure("expired direct write continued")
        } catch DirectPatchExecutionError.writeTimedOut {}
        for event in ["AstraNetworkAccessInvalidated", "AstraAuthenticationInvalidated"] {
            do {
                _ = try await DirectPatchExecutor.run(validation: {}) {
                    precondition(!Thread.isMainThread)
                    NotificationCenter.default.post(name: Notification.Name(event), object: nil)
                    try DirectPatchExecutionContext.check()
                    return true
                }
                preconditionFailure("revoked execution continued")
            } catch is CancellationError {}
        }
        let parent = Task {
            try await DirectPatchExecutor.run(validation: {}) {
                for _ in 0..<1000 {
                    try DirectPatchExecutionContext.check()
                    Thread.sleep(forTimeInterval: 0.002)
                }
                preconditionFailure("parent cancellation was not propagated")
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        parent.cancel()
        do { _ = try await parent.value; preconditionFailure("cancelled operation returned") }
        catch is CancellationError {}
        print("[PASS] production direct executor: native work off UI thread, network/auth revocation and parent cancellation")
    }
}
