import Foundation

@main enum ContainerCommitIdentitySelfCheck {
    static func main() async throws {
        try await Task.detached { try run() }.value
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
