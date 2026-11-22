import Foundation

@main enum ContainerCommitIdentitySelfCheck {
    static func main() async throws {
        try await Task.detached { try run() }.value
        try await preparedAccess()
    }
    static func preparedAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-access-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: root.appendingPathExtension("old")) }
        let roots = ["app.a": root], path = root.path
        Calls.reset()
        ExploitSupportPolicy.currentAccessProvider = .worseQuery
        Calls.identities[path] = "app.a"
        let access = try await Service.prepareAccess(roots: roots)
        precondition(Calls.released.isEmpty && Calls.next == 1, "preparation must hold its native grant")
        try Service.executePrepared(roots, access: access)
        precondition(Calls.operationRan && Calls.next == 1 && Calls.released.isEmpty,
            "writer must reuse the prepared grant without another native query")
        Calls.identities[path] = "app.other"
        Calls.operationRan = false
        do { try Service.executePrepared(roots, access: access); preconditionFailure("stale identity accepted under prepared grant") }
        catch PatchPackageError.targetAppUnavailable {}
        precondition(!Calls.operationRan && Calls.next == 1)
        Calls.identities[path] = "app.a"
        try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try Service.executePrepared(roots, access: access); preconditionFailure("replaced root accepted") }
        catch PatchPackageError.targetAppUnavailable {}
        access.release(); access.release()
        precondition(Calls.released == [1], "prepared grants must release exactly once")
        Calls.identities[path] = "app.a"
        do { try Service.executePrepared(roots, access: access); preconditionFailure("released grant accepted") }
        catch PatchPackageError.targetAppUnavailable {}
        Calls.reset()
        Calls.mcmPaths["app.a"] = path
        let fallback = try await Service.prepareAccess(roots: roots)
        try Service.executePrepared(roots, access: fallback)
        precondition(Calls.operationRan && Calls.next == 1 && Calls.events.filter { $0 == "mcm:app.a" }.count == 1,
            "system identity fallback must run before commit only")
        fallback.release()
        Calls.reset()
        do { _ = try await Service.prepareAccess(roots: roots); preconditionFailure("unverified preparation accepted") }
        catch PatchPackageError.targetAppUnavailable {}
        precondition(Calls.released == [1] && !Calls.operationRan, "failed preparation must release acquired grants")
        Calls.reset()
        ExploitSupportPolicy.currentAccessProvider = .legacy3105
        let legacy = try await Service.prepareAccess(roots: roots)
        try Service.executePrepared(roots, access: legacy)
        precondition(Calls.operationRan && Calls.next == 1, "legacy writer must reuse its native grant")
        legacy.release()
        precondition(Calls.released == [1])
        print("[PASS] pre-commit native grants: retain, reuse, identity recheck, failure cleanup and idempotent release")
    }
    static func run() throws {
        Calls.reset()
        Calls.identities["/owned/app.a"] = "app.a"
        try Service.execute(["app.a"])
        precondition(Calls.operationRan && Calls.released == [1])
        precondition(Calls.events == ["grant:/owned/app.a", "identity:/owned/app.a"])
        for unreadable in [false, true] {
            Calls.reset()
            Calls.identities["/owned/app.a"] = unreadable ? "app.a" : "app.other"
            if unreadable { Calls.unreadable.insert("/owned/app.a") }
            do { try Service.execute(["app.a"]); preconditionFailure("Unverified identity was accepted") }
            catch PatchPackageError.targetAppUnavailable { }
            precondition(!Calls.operationRan && Calls.released == [1] && Calls.invalidated == ["app.a"])
        }
        Calls.reset()
        Calls.identities["/owned/app.a"] = "app.a"
        do { try Service.execute(["app.a", "app.b"]); preconditionFailure("Second identity was accepted") }
        catch PatchPackageError.targetAppUnavailable { }
        precondition(!Calls.operationRan && Calls.released == [2,1] && Calls.invalidated == ["app.b"])
        Calls.reset()
        Calls.mcmPaths["app.a"] = "/owned/app.a"
        try Service.execute(["app.a"])
        precondition(Calls.operationRan && Calls.released == [1])
        precondition(Calls.events == ["grant:/owned/app.a", "identity:/owned/app.a", "mcm:app.a"])
        Calls.reset()
        Calls.lsPaths["app.a"] = "/owned/app.a"
        try Service.execute(["app.a"])
        precondition(Calls.operationRan && Calls.released == [1])
        for conflict in [false, true] {
            Calls.reset()
            Calls.conflict = conflict
            Calls.mcmPaths["app.a"] = conflict ? "/owned/app.a" : "/owned/reinstalled"
            Calls.lsPaths["app.a"] = "/owned/app.a"
            do { try Service.execute(["app.a"]); preconditionFailure("Conflicting or stale system binding accepted") }
            catch PatchPackageError.targetAppUnavailable { }
            precondition(!Calls.operationRan && Calls.released == [1] && Calls.invalidated == ["app.a"])
        }
        Calls.reset()
        ExploitSupportPolicy.currentAccessProvider = .legacy3105
        try Service.execute(["app.a"])
        precondition(Calls.operationRan && Calls.events.isEmpty && Calls.released == [1])
        print("Production transaction grant identity: metadata/system binding, stale/conflicting lookup refusal, multi-target cleanup and legacy separation passed")
    }
}
