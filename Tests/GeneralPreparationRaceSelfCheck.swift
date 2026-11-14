import Foundation

enum WorseQueryError: Error {
    case preparationRequired, invalidPath(String), containerDiscoveryFailed(String)
}
enum PatchPathValidator {
    static func canonicalBundleIdentifier(_ value: String) throws -> String {
        guard value.hasPrefix("com.fixture.") else { throw WorseQueryError.invalidPath(value) }
        return value
    }
}
enum ContainerStore {
    static func prepareIOS27Access(bundleIDs: [String], forceScan: Bool) throws -> [String: String] { fatalError("unexpected default transport") }
    static func prepareWorseQueryFilesystemAccess(forceScan: Bool) throws { fatalError("unexpected default general transport") }
    static func isApplicationContainerPath(_ path: String) -> Bool {
        path.hasPrefix("/private/var/mobile/Containers/Data/Application/") && UUID(uuidString: String(path.split(separator: "/").last!)) != nil
    }
}
final class Barrier: @unchecked Sendable {
    private let lock = NSLock()
    private var callStorage: [[String]] = []
    private var activeStorage = 0, maxStorage = 0
    let release = DispatchSemaphore(value: 0)
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return callStorage }
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return maxStorage }
    func run(_ targets: [String], waiting: Bool) -> [String: String] {
        lock.lock(); callStorage.append(targets); activeStorage += 1; maxStorage = max(maxStorage, activeStorage); lock.unlock()
        if waiting { release.wait() }
        lock.lock(); activeStorage -= 1; lock.unlock()
        return Dictionary(uniqueKeysWithValues: targets.map { ($0, $0 == "com.fixture.a" ? roots[0] : roots[1]) })
    }
}
let roots = ["/private/var/mobile/Containers/Data/Application/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
             "/private/var/mobile/Containers/Data/Application/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"]

@main struct PreparationRaceChecks {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        preconditionFailure("fixture timed out")
    }
    @MainActor static func main() async throws {
        // A daemon call may not finish immediately on cancellation/reset. Its
        // late successful result must never republish roots into a new session.
        let barrier = Barrier()
        let first = IOS27ContainerPreparation(progress: ContainerScanProgress(historyURL: nil), operation: { targets, _ in
            barrier.run(targets, waiting: true)
        }, generalOperation: { _ in _ = barrier.run([], waiting: true) })
        first.configureTargets(bundleIDs: ["com.fixture.a"])
        let old = Task { @MainActor in await first.prepareIfNeeded() }
        await until { barrier.calls.count == 1 }
        first.reset()
        barrier.release.signal()
        await old.value
        precondition(first.state == .idle && !first.didContinue)
        precondition(IOS27ContainerSession.path(for: "com.fixture.a") == nil)
        print("PASS: reset suppresses late native-success publication")

        let cancelBarrier = Barrier()
        let canceled = IOS27ContainerPreparation(progress: ContainerScanProgress(historyURL: nil), operation: { targets, _ in
            cancelBarrier.run(targets, waiting: true)
        }, generalOperation: { _ in _ = cancelBarrier.run([], waiting: true) })
        canceled.configureTargets(bundleIDs: ["com.fixture.a"])
        let caller = Task { @MainActor in await canceled.prepareIfNeeded() }
        await until { cancelBarrier.calls.count == 1 }
        caller.cancel()
        cancelBarrier.release.signal()
        await caller.value
        precondition(canceled.state == .failed && !canceled.didContinue)
        precondition(IOS27ContainerSession.path(for: "com.fixture.a") == nil)
        print("PASS: cancellation suppresses successful worker result")

        let concurrent = Barrier()
        let ready = IOS27ContainerPreparation(progress: ContainerScanProgress(historyURL: nil), operation: { targets, _ in
            concurrent.run(targets, waiting: concurrent.calls.count >= 1)
        }, generalOperation: { _ in _ = concurrent.run([], waiting: false) })
        ready.configureTargets(bundleIDs: ["com.fixture.a"])
        await ready.prepareIfNeeded()
        precondition(IOS27ContainerSession.path(for: "com.fixture.a") == nil,
                     "general scan published a game root")
        ready.enterApplication()
        precondition(ready.didContinue)
        let a = Task { @MainActor in try await ready.prepareAdditionalTargets(bundleIDs: ["com.fixture.a"]) }
        await until { concurrent.calls.count == 2 }
        let b = Task { @MainActor in try await ready.prepareAdditionalTargets(bundleIDs: ["com.fixture.b"]) }
        try await Task.sleep(nanoseconds: 15_000_000)
        precondition(concurrent.calls.count == 2, "concurrent preparation invoked native twice")
        concurrent.release.signal()
        try await a.value
        await until { concurrent.calls.count == 3 }
        concurrent.release.signal()
        try await b.value
        precondition(concurrent.maxActive == 1)
        precondition(IOS27ContainerSession.path(for: "com.fixture.a") == roots[0])
        precondition(IOS27ContainerSession.path(for: "com.fixture.b") == roots[1])
        print("PASS: concurrent additional-target requests serialize and merge independently verified roots")

        // Returning a plausible directory under an unrequested identifier must
        // not broaden the patch's targets even after a successful operation.
        let invalid = IOS27ContainerPreparation(progress: ContainerScanProgress(historyURL: nil), operation: { _, _ in
            ["com.fixture.b": roots[1]]
        }, generalOperation: { _ in })
        invalid.configureTargets(bundleIDs: ["com.fixture.a"])
        await invalid.prepareIfNeeded()
        precondition(invalid.state == .ready && !invalid.didContinue,
                     "general readiness must not resolve game targets")
        invalid.enterApplication()
        do {
            try await invalid.prepareAdditionalTargets(bundleIDs: ["com.fixture.a"])
            preconditionFailure("out-of-scope additional root published")
        } catch WorseQueryError.invalidPath {}
        precondition(invalid.state == .ready && invalid.didContinue)
        precondition(IOS27ContainerSession.path(for: "com.fixture.a") == nil && IOS27ContainerSession.path(for: "com.fixture.b") == nil)
        print("PASS: out-of-scope worker roots cannot publish")
        invalid.reset()
    }
}
