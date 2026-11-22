import Foundation

@main struct ToggleRecoveryFlowSelfCheck {
    @MainActor private static var checks = 0
    @MainActor private static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw CatalogCheckError.failed(message) }
        checks += 1
    }

    @MainActor private static func associate(_ service: FeaturePatchService,
                                              projectID: UUID) {
        service.catalogApplications.associate(projectID, with: "catalog_1_ffth")
        service.catalogApplications.markApplied("catalog_1_ffth")
    }

    @MainActor private static func cancellationDuringRecovery(_ error: Error,
                                                              label: String) async throws {
        try Fixture.reset()
        ToggleRecoveryBoundary.receiptPreparationError = nil
        ToggleRecoveryBoundary.receiptPreparationCalls = 0
        defer { ToggleRecoveryBoundary.receiptPreparationError = nil }
        let auth = AuthManager(), item = PatchItem(id: 1, name: "Fixture", slug: "fixture")
        let service = FeaturePatchService()
        try await service.applyPatch(item, auth: auth)
        let projectID = Fixture.nextProject.id, originalReceipt = Fixture.receipts[Fixture.nextProject.id]!
        Fixture.failRestore = true
        do {
            try await service.restorePatch(item, auth: auth)
            throw CatalogCheckError.failed("Injected OFF failure was ignored")
        } catch CatalogCheckError.writeFailure {}
        Fixture.failRestore = false
        let ui = ToggleRecoveryHarness(service: service, authManager: auth)
        ui.tap(item)
        await ui.awaitAction()
        guard let review = ui.review else { throw CatalogCheckError.failed("No recovery review for " + label) }
        try check(review.confirmation.changedPaths.isEmpty, "Cancellation fixture unexpectedly needs force")
        let preparations = ToggleRecoveryBoundary.receiptPreparationCalls
        ToggleRecoveryBoundary.receiptPreparationError = error
        do {
            try await service.applyPatch(item, auth: auth, recoveryConfirmation: review.confirmation)
            throw CatalogCheckError.failed("Recovery preparation cancellation was ignored: " + label)
        } catch {
            try check(FeaturePatchService.isPatchOperationCancellation(error),
                      "Recovery cancellation became retryNeedsRecovery: " + label)
            try check(!PatchRestoreError.requiresRestoreReview(error),
                      "Canceled recovery incorrectly requests another error review: " + label)
        }
        try check(ToggleRecoveryBoundary.receiptPreparationCalls > preparations,
                  "Cancellation was not injected inside old-receipt recovery preparation")
        try check(Fixture.restores == 0 && Fixture.applies == 1 && Fixture.receipts[projectID] == originalReceipt,
                  "Canceled recovery changed files or replaced its original receipt: " + label)
        try check(!service.patchOperationInProgress && service.patchOperation == nil,
                  "Canceled recovery did not release operation progress: " + label)
        ui.confirmReview()
        await ui.awaitAction()
        try check(ui.toast == nil && ui.review == nil,
                  "Canceled recovery emitted a failure/success toast or reopened review: " + label)
        try check(!service.isPatchEnabled(item) && Fixture.restores == 0 && Fixture.applies == 1,
                  "Canceled recovery enabled the toggle or continued mutation: " + label)
    }

    @MainActor static func main() async throws {
        let auth = AuthManager(), item = PatchItem(id: 1, name: "Fixture", slug: "fixture")
        try Fixture.reset()
        do {
            let independent = FeaturePatchService()
            independent.independentCatalogToggles = true
            let second = PatchItem(id: 2, name: "Second", slug: "second")
            let ui = ToggleRecoveryHarness(service: independent, authManager: auth)
            ui.tap(item); await ui.awaitAction()
            let a = independent.catalogApplications.projectID(for: "catalog_1_ffth")
            ui.tap(second); await ui.awaitAction()
            let b = independent.catalogApplications.projectID(for: "catalog_2_ffth")
            try check(a != nil && b != nil && a != b, "reused package ID must not link two catalog switches")
            try check(independent.isPatchEnabled(item) && independent.isPatchEnabled(second), "two overlapping features must both enable")
            try check(ui.review == nil && Fixture.applies == 2 && Fixture.restores == 0, "ON must overwrite without recovery or review")
            Fixture.changed = true
            ui.tap(item); await ui.awaitAction()
            try check(ui.review == nil && !independent.isPatchEnabled(item) && independent.isPatchEnabled(second), "OFF must not prompt or disable a different feature")
            ui.tap(item); await ui.awaitAction()
            try check(ui.review == nil && independent.isPatchEnabled(item) && independent.isPatchEnabled(second), "independent ON retry must not demand old recovery")
            ui.showFixtureFailure(NSError(domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "com.example.game/Documents/private-file"]))
            try check(ui.toast?.message.contains("/") == false && ui.toast?.message.contains("com.example") == false,
                      "public error revealed target path or Bundle ID")
        }
        try Fixture.reset()
        defer { try? FileManager.default.removeItem(at: Fixture.root) }
        let service = FeaturePatchService()
        try await service.applyPatch(item, auth: auth)
        let projectID = Fixture.nextProject.id
        let originalReceipt = Fixture.receipts[projectID]!
        Fixture.failRestore = true
        do {
            try await service.restorePatch(item, auth: auth)
            throw CatalogCheckError.failed("Injected OFF failure was ignored")
        } catch CatalogCheckError.writeFailure {}
        Fixture.failRestore = false
        try check(!service.isPatchEnabled(item) && service.patchApplicationState(item) == .applied,
                  "Failed OFF did not retain separate intent and actual file state")

        let ui = ToggleRecoveryHarness(service: service, authManager: auth)
        for _ in 0..<3 {
            ui.tap(item)
            await ui.awaitAction()
            try check(ui.review != nil && ui.review?.confirmation.changedPaths.isEmpty == true,
                      "OFF failure with unchanged target is stranded behind the OFF toggle")
            try check(ui.review?.reenablePatch?.id == item.id,
                      "Existing review is not connected to confirmed re-enable")
            ui.cancelReview()
            try check(!service.isPatchEnabled(item) && Fixture.restores == 0 && Fixture.applies == 1,
                      "Cancel/repeated review performed file I/O or enabled the toggle")
            try check(Fixture.receipts[projectID] == originalReceipt && Fixture.downloads == 1,
                      "Unconfirmed retry replaced its receipt or downloaded a new baseline")
        }
        ui.tap(item)
        await ui.awaitAction()
        ui.confirmReview()
        await ui.awaitAction()
        try check(Fixture.restores == 1 && Fixture.applies == 2 && !Fixture.forcedRestore,
                  "Unchanged-target confirmation must restore normally before a fresh apply")
        try check(service.isPatchEnabled(item) && ui.toast?.isSuccess == true,
                  "Confirmed restore/re-enable failed to publish successful ON")
        try check(Fixture.receipts[projectID]?.id != originalReceipt.id &&
                  FileManager.default.fileExists(atPath: originalReceipt.journalURL.path),
                  "Confirmed retry deleted the previous recovery evidence")

        // A prepared/incomplete transaction is not necessarily an explicit OFF
        // request. Its safe recovery still needs a reachable existing UI flow.
        try Fixture.reset()
        let interrupted = FeaturePatchService(), interruptedProject = Fixture.nextProject.id
        try Fixture.establish(interruptedProject, state: .recoveryRequired)
        associate(interrupted, projectID: interruptedProject)
        let interruptedReceipt = Fixture.receipts[interruptedProject]!
        let partialUI = ToggleRecoveryHarness(service: interrupted, authManager: auth)
        partialUI.tap(item)
        await partialUI.awaitAction()
        try check(!interrupted.isPatchEnabled(item) && partialUI.review != nil,
                  "Prepared recovery has no reachable review on the current toggle")
        try check(Fixture.downloads == 0 && Fixture.restores == 0 && Fixture.applies == 0,
                  "Opening prepared recovery touched payload or target state")
        partialUI.confirmReview()
        await partialUI.awaitAction()
        try check(Fixture.restores == 1 && Fixture.applies == 1 && !Fixture.forcedRestore,
                  "Prepared recovery did not restore before the new application")
        try check(interrupted.isPatchEnabled(item) &&
                  FileManager.default.fileExists(atPath: interruptedReceipt.journalURL.path),
                  "Prepared recovery retry lost old evidence or failed to enable")

        // Changed paths require the existing review, never unconfirmed force.
        try Fixture.reset()
        let changed = FeaturePatchService()
        try await changed.applyPatch(item, auth: auth)
        Fixture.failRestore = true
        do {
            try await changed.restorePatch(item, auth: auth)
            throw CatalogCheckError.failed("Injected changed OFF failure was ignored")
        } catch CatalogCheckError.writeFailure {}
        Fixture.failRestore = false
        Fixture.changed = true
        let changedUI = ToggleRecoveryHarness(service: changed, authManager: auth)
        changedUI.tap(item)
        await changedUI.awaitAction()
        try check(changedUI.review?.confirmation.changedPaths.count == 1 && Fixture.restores == 0,
                  "Changed target was restored without an explicit review")
        changedUI.cancelReview()
        try check(!changed.isPatchEnabled(item) && Fixture.restores == 0,
                  "Canceling changed-target review changed requested state")

        // Missing durable evidence remains a reported error. The recovery route
        // must not fabricate permission to apply or silently discard backups.
        try Fixture.reset()
        let missing = FeaturePatchService(), missingProject = Fixture.nextProject.id
        try Fixture.establish(missingProject, state: .recoveryRequired)
        associate(missing, projectID: missingProject)
        Fixture.receipts[missingProject] = nil
        let missingUI = ToggleRecoveryHarness(service: missing, authManager: auth)
        missingUI.tap(item)
        await missingUI.awaitAction()
        try check(missingUI.review == nil && missingUI.toast?.isSuccess == false,
                  "Missing receipt was presented as a restorable confirmation")
        try check(!missing.isPatchEnabled(item) && Fixture.applies == 0 && Fixture.restores == 0,
                  "Missing receipt recovery mutated files or enabled the toggle")
        // Screenshot P03: the downloaded package has a live receipt but no
        // association with the current catalog item. Never adopt it silently.
        for changedTargets in [false, true] {
            try Fixture.reset()
            let orphan = FeaturePatchService(), orphanID = Fixture.nextProject.id
            try Fixture.establish(orphanID)
            let oldReceipt = Fixture.receipts[orphanID]!
            Fixture.changed = changedTargets
            let orphanUI = ToggleRecoveryHarness(service: orphan, authManager: auth)
            orphanUI.tap(item)
            await orphanUI.awaitAction()
            try check(orphanUI.review?.confirmation.projectID == orphanID,
                      "Unassociated package history stranded the OFF toggle")
            try check(orphanUI.review?.confirmation.changedPaths.isEmpty == !changedTargets,
                      "Unassociated recovery skipped target inspection")
            try check(orphan.catalogApplications.projectID(for: "catalog_1_ffth") == nil,
                      "Unconfirmed package history was adopted by current catalog")
            orphanUI.cancelReview()
            try check(Fixture.restores == 0 && Fixture.applies == 0 && Fixture.receipts[orphanID] == oldReceipt,
                      "Cancel changed orphan files or backup")
            orphanUI.tap(item)
            await orphanUI.awaitAction()
            orphanUI.confirmReview()
            await orphanUI.awaitAction()
            try check(Fixture.restores == 1 && Fixture.applies == 1 && orphan.isPatchEnabled(item),
                      "Confirmed orphan recovery did not restore then apply")
            try check(Fixture.forcedRestore == changedTargets,
                      "Unassociated recovery invented or lost changed-target permission")
            try check(FileManager.default.fileExists(atPath: oldReceipt.journalURL.path),
                      "Unassociated recovery deleted old backup evidence")
        }
        try Fixture.reset()
        let failedOrphan = FeaturePatchService(), failedID = Fixture.nextProject.id
        try Fixture.establish(failedID)
        let failedUI = ToggleRecoveryHarness(service: failedOrphan, authManager: auth)
        failedUI.tap(item); await failedUI.awaitAction()
        Fixture.failRestore = true
        failedUI.confirmReview(); await failedUI.awaitAction()
        try check(Fixture.applies == 0 && Fixture.states[failedID] == .applied,
                  "Failed unassociated restore continued to fresh apply")
        try check(failedUI.toast?.isSuccess == false && Fixture.receipts[failedID] != nil,
                  "Failed unassociated restore lost receipt or reported success")

        try Fixture.reset()
        let staleOrphan = FeaturePatchService(), staleID = Fixture.nextProject.id
        try Fixture.establish(staleID)
        let staleUI = ToggleRecoveryHarness(service: staleOrphan, authManager: auth)
        staleUI.tap(item); await staleUI.awaitAction()
        auth.authenticationRevision += 1
        staleUI.confirmReview(); await staleUI.awaitAction()
        try check(Fixture.restores == 0 && Fixture.applies == 0,
                  "Stale authentication accepted unassociated recovery confirmation")

        try await cancellationDuringRecovery(CancellationError(), label: "CancellationError")
        try await cancellationDuringRecovery(URLError(.cancelled), label: "URLError.cancelled")
        print("Actual toggle/restore review flow: \(checks) checks passed")
    }
}
