import Foundation

fileprivate final class DirectPatchPermit: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private let deadline: TimeInterval
    init(timeout: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + timeout }
    func revoke() { lock.lock(); revoked = true; lock.unlock() }
    func check() throws {
        try Task.checkCancellation()
        lock.lock(); let invalid = revoked; lock.unlock()
        if invalid { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw DirectPatchExecutionError.writeTimedOut }
    }
}

enum DirectPatchExecutionContext {
    fileprivate static let key = "astra.direct-patch.permit"
    static func check() throws {
        try Task.checkCancellation()
        try (Thread.current.threadDictionary[key] as? DirectPatchPermit)?.check()
    }
    fileprivate static func execute<T>(_ permit: DirectPatchPermit, operation: () throws -> T) throws -> T {
        try permit.check()
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = permit
        defer {
            if let previous { dictionary[key] = previous }
            else { dictionary.removeObject(forKey: key) }
        }
        return try operation()
    }
}

/// Native query, backup/write/verify and rollback never occupy MainActor.
/// Revocation is checked before forward writes; rollback remains uninterrupted.
enum DirectPatchExecutor {
    static func run<T: Sendable>(timeout: TimeInterval = 180,
                       validation: @escaping @MainActor @Sendable () throws -> Void,
                       operation: @escaping @Sendable () throws -> T) async throws -> T {
        let permit = DirectPatchPermit(timeout: timeout)
        let notifications = NotificationCenter.default
        let observers = ["AstraNetworkAccessInvalidated", "AstraAuthenticationInvalidated"].map { name in
            notifications.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in permit.revoke() }
        }
        defer { observers.forEach { notifications.removeObserver($0) } }
        let task = Task.detached(priority: .userInitiated) {
            try permit.check()
            try await validation()
            try permit.check()
            return try DirectPatchExecutionContext.execute(permit, operation: operation)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { permit.revoke(); task.cancel() })
    }
}

// BEGIN READ-ONLY PATCH PREPARATION
enum DirectPatchExecutionError: LocalizedError {
    case preparationBusy, preparationTimedOut, writeTimedOut
    var errorDescription: String? {
        switch self {
        case .preparationBusy: return "Hệ thống vẫn đang kết thúc bước chuẩn bị trước. Vui lòng thử lại sau."
        case .preparationTimedOut: return "Chuẩn bị chức năng quá thời gian chờ. Vui lòng thử lại."
        case .writeTimedOut: return "Thao tác dữ liệu quá thời gian chờ và đã dừng. Vui lòng thử lại."
        }
    }
}

/// A timed-out native lookup may still be inside an OS call. Keep its slot
/// until it returns, reject retries promptly, and discard its late result.
private enum DirectPatchPreparationSlot {
    static let lock = NSLock()
    static var owner: UUID?
    static func acquire() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { throw DirectPatchExecutionError.preparationBusy }
        let id = UUID(); owner = id; return id
    }
    static func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner == id { owner = nil }
    }
}

private final class DirectPatchPreparationJob<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var buffered: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var worker: Task<Void, Never>?
    private var timer: DispatchWorkItem?

    func install(_ value: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result = buffered {
            buffered = nil; lock.unlock(); value.resume(with: result)
        } else { continuation = value; lock.unlock() }
    }
    func install(_ task: Task<Void, Never>) {
        lock.lock()
        let cancel = settled
        if !cancel { worker = task }
        lock.unlock()
        if cancel { task.cancel() }
    }
    func check() throws {
        lock.lock(); let stopped = settled; lock.unlock()
        if stopped { throw CancellationError() }
        try Task.checkCancellation()
    }
    func arm(timeout: TimeInterval) {
        let item = DispatchWorkItem { [self] in
            complete(.failure(DirectPatchExecutionError.preparationTimedOut), cancelWorker: true)
        }
        lock.lock()
        if settled { lock.unlock(); return }
        timer = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
    }
    func complete(_ result: Result<Value, Error>, cancelWorker: Bool = false) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let waiter = continuation, task = worker, alarm = timer
        continuation = nil; worker = nil; timer = nil
        if waiter == nil { buffered = result }
        lock.unlock()
        alarm?.cancel()
        if cancelWorker { task?.cancel() }
        waiter?.resume(with: result)
    }
}

/// Only decode/discovery belongs here. Never race a filesystem write against
/// this timeout: writes must retain their gate until verification/rollback ends.
enum DirectPatchPreparation {
    static func run<Value: Sendable>(timeout: TimeInterval = 45,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let id = try DirectPatchPreparationSlot.acquire()
        let job = DirectPatchPreparationJob<Value>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                job.install(continuation)
                let worker = Task.detached(priority: .userInitiated) {
                    let result: Result<Value, Error>
                    do {
                        try job.check()
                        let value = try await operation()
                        try job.check()
                        result = .success(value)
                    } catch { result = .failure(error) }
                    DirectPatchPreparationSlot.release(id)
                    job.complete(result)
                }
                job.install(worker)
                job.arm(timeout: timeout)
            }
        }, onCancel: { job.complete(.failure(CancellationError()), cancelWorker: true) })
    }
}
// END READ-ONLY PATCH PREPARATION
