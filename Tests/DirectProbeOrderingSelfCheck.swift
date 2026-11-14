import Foundation

@main enum DirectProbeOrderingSelfCheck {
    static func main() {
        let pending = Probe()
        pending.consider()
        precondition(pending.attempts == 0)
        pending.isCheckingDirectAccess = true
        pending.consider()
        precondition(pending.attempts == 0)
        pending.finish(true)
        precondition(pending.attempts == 0 && pending.didCheckDirectAccess)
        let refused = Probe()
        refused.isCheckingDirectAccess = true
        refused.finish(false)
        precondition(refused.attempts == 1 && refused.autoRunAttempted)
        refused.consider()
        precondition(refused.attempts == 1)
        let inactiveProvider = Probe()
        inactiveProvider.kernelExploitApplicable = false
        inactiveProvider.finish(false)
        precondition(inactiveProvider.attempts == 0)
        let sandbox = Probe()
        sandbox.hasSandboxAccess = true
        sandbox.finish(false)
        precondition(sandbox.attempts == 0)
        print("Production direct probe ordering: pending, success, failure, retry and provider checks passed")
    }
}
