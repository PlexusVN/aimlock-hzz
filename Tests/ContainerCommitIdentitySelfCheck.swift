import Foundation

@main enum ContainerCommitIdentitySelfCheck {
    static func main() throws {
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
        ExploitSupportPolicy.currentAccessProvider = .legacy3105
        try Service.execute(["app.a"])
        precondition(Calls.operationRan && Calls.events.isEmpty && Calls.released == [1])
        print("Production transaction grant identity: match, mismatch, unreadable, multi-target cleanup and legacy separation passed")
    }
}
