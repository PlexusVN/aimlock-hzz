import Foundation

@main struct CatalogRecoverySelfCheck {
    @MainActor static var checks=0
    @MainActor static func check(_ value:Bool,_ message:String)throws {
        guard value else { throw CatalogCheckError.failed(message) }
        checks += 1
    }
    @MainActor static func mustFail(_ message:String,_ operation:()async throws->Void)async throws {
        do { try await operation() }
        catch { checks += 1;return }
        throw CatalogCheckError.failed(message)
    }
    @MainActor static func associate(_ service:FeaturePatchService,_ item:PatchItem,_ project:UUID) {
        service.catalogApplications.associate(project,with:"catalog_\(item.id)_fixture")
        service.catalogApplications.markApplied("catalog_\(item.id)_fixture")
    }
    @MainActor static func queuedSessionCheck(_ kind:String)async throws {
        try Fixture.reset()
        let service=FeaturePatchService(),auth=AuthManager(),item=PatchItem(id:1,name:"Fixture",slug:"fixture")
        if kind != "apply" { try Fixture.establish(Fixture.nextProject.id);associate(service,item,Fixture.nextProject.id) }
        let held=try await PatchFilesystemGate.shared.acquire()
        let task=Task { @MainActor in
            switch kind {
            case "apply":try await service.applyPatch(item,auth:auth)
            case "restore":try await service.restorePatch(item,auth:auth)
            default:_ = try await service.inspectPatchRestore(item,auth:auth)
            }
        }
        while !service.patchOperationInProgress { await Task.yield() }
        auth.authState = .idle;auth.authenticationRevision=2
        auth.authState = .verified;auth.authenticationRevision=3
        await PatchFilesystemGate.shared.release(held)
        try await mustFail("queued \(kind) crossed authentication revision") { try await task.value }
        try check(Fixture.downloads==0 && Fixture.applies==0 && Fixture.restores==0,"queued \(kind) changed files")
        try check(!service.patchOperationInProgress,"queued failure retained busy state")
    }
    @MainActor static func main()async throws {
        let item=PatchItem(id:1,name:"Feature\nOne",slug:"fixture")
        try Fixture.reset()
        let service=FeaturePatchService(),auth=AuthManager(),oldID=UUID()
        try Fixture.establish(oldID);associate(service,item,oldID)
        let oldReceipt=Fixture.receipts[oldID]
        Fixture.failApply=true
        try await mustFail("failed replacement ignored") { try await service.applyPatch(item,auth:auth) }
        try check(service.catalogApplications.projectID(for:"catalog_1_fixture")==oldID,"active association replaced")
        try check(Fixture.receipts[oldID]==oldReceipt && Fixture.restores==1,"replacement failed without safely retiring or retaining the old backup")
        try check(!service.isPatchEnabled(item),"failed ON request remained visually enabled")
        try await service.restorePatch(item,auth:auth)
        try check(Fixture.restores==1 && !Fixture.forcedRestore,"normal OFF must use safe restore")

        try Fixture.reset()
        let incoming=FeaturePatchService()
        try Fixture.establish(Fixture.nextProject.id)
        try await mustFail("incoming project already active under another item was adopted") {
            try await incoming.applyPatch(item,auth:auth)
        }
        try check(Fixture.applies==0 && incoming.catalogApplications.projectID(for:"catalog_1_fixture")==nil,
                  "incoming active project mutated a new catalog association")

        try Fixture.reset()
        let first=FeaturePatchService();Fixture.failApply=true
        try await mustFail("pre-journal failure ignored") { try await first.applyPatch(item,auth:auth) }
        try check(first.catalogApplications.projectID(for:"catalog_1_fixture")==nil,"uncommitted association not removed")
        try check(first.recoveryItems.isEmpty,"harmless pre-journal metadata became an active transaction")
        Fixture.failApply=false
        try await first.applyPatch(item,auth:auth)
        let projectID=Fixture.nextProject.id
        try check(first.recoveryItems.count==1 && first.recoveryItems[0].projectID==projectID,"new application missing from recovery")
        try check(first.recoveryItems[0].title=="FeatureOne","display metadata did not sanitize control characters")
        let metadataURL=Fixture.root.appendingPathComponent(".catalog-recovery.plist")
        let rows=try PropertyListSerialization.propertyList(from:Data(contentsOf:metadataURL),format:nil) as! [[String:Any]]
        try check(Set(rows[0].keys)==Set(["projectID","title","catalogIdentity","requestedEnabled","requestedBinding"]),"recovery metadata contains payload/auth/URL fields")
        for key in Fixture.defaults.dictionaryRepresentation().keys { Fixture.defaults.removeObject(forKey:key) }
        let restarted=FeaturePatchService();restarted.refreshRecoveryItems()
        try check(restarted.recoveryItems.count==1 && restarted.recoveryItems[0].title=="FeatureOne","restart or preference loss hid durable recovery")
        try check(restarted.patchApplicationState(item) == .applied,"preference loss made the main catalog card display OFF")
        let recoveredCatalogReview=try await restarted.inspectPatchRestore(item,auth:auth)
        try check(recoveredCatalogReview.projectID==projectID,"main catalog inspection did not recover the durable project identity")
        let downloadsBeforeRetry=Fixture.downloads
        let preservedReceipt=Fixture.receipts[projectID]!.id,appliesBeforeRetry=Fixture.applies
        try await restarted.applyPatch(item,auth:auth)
        try check(Fixture.downloads==downloadsBeforeRetry+1 && Fixture.applies==appliesBeforeRetry,
                  "verified same-project retry recaptured a new baseline")
        try check(Fixture.receipts[projectID]?.id==preservedReceipt,"same-project retry replaced the original receipt")
        // A server catalog is not involved: restore through durable project ID.
        let recovery=restarted.recoveryItems[0]
        let normalReview=try await restarted.inspectRecoveryRestore(recovery,auth:auth)
        try check(normalReview.changedPaths.isEmpty,"unchanged target unexpectedly forced")
        try await restarted.restoreRecovery(recovery,auth:auth,confirmation:normalReview)
        try check(restarted.recoveryItems.isEmpty && Fixture.restores==1,"recovery OFF did not retire restored state")

        try Fixture.reset()
        let lostPreferences=FeaturePatchService()
        try await lostPreferences.applyPatch(item,auth:auth)
        for key in Fixture.defaults.dictionaryRepresentation().keys { Fixture.defaults.removeObject(forKey:key) }
        let catalogAfterRestart=FeaturePatchService()
        try check(catalogAfterRestart.isPatchApplied(item),"restart card did not recover durable ON state")
        let mainReview=try await catalogAfterRestart.inspectPatchRestore(item,auth:auth)
        try await catalogAfterRestart.restorePatch(item,auth:auth,confirmation:mainReview)
        try check(Fixture.restores==1 && catalogAfterRestart.patchApplicationState(item) == .off,
                  "main catalog OFF failed after preference loss")

        try Fixture.reset()
        let ambiguous=FeaturePatchService(),a=UUID(),b=UUID()
        try Fixture.establish(a);try Fixture.establish(b);associate(ambiguous,item,a)
        let metadata:[[String:Any]]=[
            ["projectID":a.uuidString,"title":"A","catalogIdentity":"catalog_1_fixture"],
            ["projectID":b.uuidString,"title":"B","catalogIdentity":"catalog_1_fixture"]]
        let encoded=try PropertyListSerialization.data(fromPropertyList:metadata,format:.binary,options:0)
        try encoded.write(to:Fixture.root.appendingPathComponent(".catalog-recovery.plist"))
        ambiguous.refreshRecoveryItems()
        try check(ambiguous.patchApplicationState(item) == .recoveryRequired && ambiguous.recoveryItems.count==2,
                  "multiple active histories silently selected one catalog project")
        try await mustFail("ambiguous catalog inspection selected an arbitrary project") {
            _ = try await ambiguous.inspectPatchRestore(item,auth:auth)
        }
        try await mustFail("ambiguous catalog OFF selected an arbitrary project") {
            try await ambiguous.restorePatch(item,auth:auth)
        }
        let explicitlySelected=ambiguous.recoveryItems.first { $0.projectID==a }!
        let explicitReview=try await ambiguous.inspectRecoveryRestore(explicitlySelected,auth:auth)
        try await ambiguous.restoreRecovery(explicitlySelected,auth:auth,confirmation:explicitReview)
        try check(Fixture.restores==1 && ambiguous.recoveryItems.count==1 && ambiguous.recoveryItems[0].projectID==b,
                  "explicit recovery of one project affected another active history")

        try Fixture.reset()
        let partial=FeaturePatchService();Fixture.partialApply=true
        try await mustFail("partial application ignored") { try await partial.applyPatch(item,auth:auth) }
        try check(partial.catalogApplications.projectID(for:"catalog_1_fixture")==Fixture.nextProject.id,"partial journal lost association")
        try check(partial.recoveryItems.first?.state == .recoveryRequired,"partial write advertised OFF")

        try Fixture.reset()
        let changed=FeaturePatchService();try Fixture.establish(Fixture.nextProject.id);associate(changed,item,Fixture.nextProject.id)
        Fixture.changed=true
        try await mustFail("default OFF overwrote changed targets") { try await changed.restorePatch(item,auth:auth) }
        try check(Fixture.restores==0 && changed.isPatchApplied(item),"changed-target refusal lost ON or restored data")
        let review=try await changed.inspectPatchRestore(item,auth:auth)
        try check(review.changedPaths==["com.fixture.app/Documents/file"],"inspection did not provide changed paths")
        Fixture.snapshot=Data([9,8,7])
        try await mustFail("stale inspected bytes accepted") { try await changed.restorePatch(item,auth:auth,confirmation:review) }
        try check(Fixture.restores==0,"stale review wrote files")
        let freshReview=try await changed.inspectPatchRestore(item,auth:auth)
        auth.authenticationRevision += 1
        try await mustFail("review crossed sessions") { try await changed.restorePatch(item,auth:auth,confirmation:freshReview) }
        let finalReview=try await changed.inspectPatchRestore(item,auth:auth)
        try await changed.restorePatch(item,auth:auth,confirmation:finalReview)
        try check(Fixture.restores==1 && Fixture.forcedRestore,"explicit current review did not authorize force restore")
        try check(!changed.isPatchApplied(item),"successful confirmed OFF retained application flags")

        try Fixture.reset()
        let replaced=FeaturePatchService()
        try Fixture.establish(Fixture.nextProject.id);associate(replaced,item,Fixture.nextProject.id)
        let receiptReview=try await replaced.inspectPatchRestore(item,auth:auth)
        try Fixture.establish(Fixture.nextProject.id)
        try await mustFail("confirmation restored a different receipt") {
            try await replaced.restorePatch(item,auth:auth,confirmation:receiptReview)
        }
        try check(Fixture.restores==0,"changed receipt confirmation reached mutation")

        for kind in ["apply","restore","inspect"] { try await queuedSessionCheck(kind) }

        try Fixture.reset()
        let concurrent=FeaturePatchService(),held=try await PatchFilesystemGate.shared.acquire()
        let firstQueued=Task { @MainActor in try await concurrent.applyPatch(item,auth:auth) }
        let secondQueued=Task { @MainActor in try await concurrent.applyPatch(item,auth:auth) }
        for _ in 0..<100 { await Task.yield() }
        try check(concurrent.patchOperationInProgress,"queued operations did not publish busy state")
        await PatchFilesystemGate.shared.release(held)
        var successes=0,refusals=0
        for task in [firstQueued,secondQueued] {
            do { try await task.value;successes += 1 }
            catch { refusals += 1 }
        }
        try check(successes==2 && refusals==0 && Fixture.applies==1 && Fixture.downloads==2,
                  "two queued ON requests did not reuse the original verified application")
        try check(!concurrent.patchOperationInProgress,"completed queue retained busy state")

        // User intent is OFF even when restoration fails. Actual history and
        // original backup remain authoritative and available for recovery.
        try Fixture.reset()
        let retry=FeaturePatchService()
        try await retry.applyPatch(item,auth:auth)
        let originalProject=Fixture.nextProject.id, originalReceipt=Fixture.receipts[Fixture.nextProject.id]!
        let originalApplies=Fixture.applies
        try check(retry.isPatchEnabled(item),"successful ON did not persist requested state")
        Fixture.failRestore=true
        try await mustFail("injected OFF failure ignored") { try await retry.restorePatch(item,auth:auth) }
        try check(!retry.isPatchEnabled(item) && retry.patchApplicationState(item) == .applied,
                  "failed OFF either stayed visually ON or lied about actual restoration")
        try check(Fixture.receipts[originalProject]==originalReceipt && retry.recoveryItems.first?.requestedEnabled==false,
                  "failed OFF lost original backup or recovery warning intent")
        for key in Fixture.defaults.dictionaryRepresentation().keys { Fixture.defaults.removeObject(forKey:key) }
        let afterOffRestart=FeaturePatchService()
        try check(!afterOffRestart.isPatchEnabled(item),"failed OFF was not recovered from durable intent metadata after preference loss")
        Fixture.failRestore=false
        try await afterOffRestart.applyPatch(item,auth:auth)
        try check(afterOffRestart.isPatchEnabled(item) && Fixture.applies==originalApplies,
                  "ON after failed OFF did not adopt the verified existing application")
        try check(Fixture.receipts[originalProject]==originalReceipt,"ON retry created a backup from patched bytes")

        // Cancelling the changed-file review does not issue OFF. A real
        // noncancel inspection error can record OFF without touching targets.
        Fixture.changed=true
        let cancelledReview=try await afterOffRestart.inspectPatchRestore(item,auth:auth)
        try check(!cancelledReview.changedPaths.isEmpty && afterOffRestart.isPatchEnabled(item),
                  "opening/cancelling a review changed requested ON state")
        let inspectionRevision=auth.authenticationRevision
        Fixture.failInspect=true
        try await mustFail("inspection failure ignored") { _ = try await afterOffRestart.inspectPatchRestore(item,auth:auth) }
        afterOffRestart.recordPatchOffFailure(item,requestedRevision:inspectionRevision,auth:auth)
        try check(!afterOffRestart.isPatchEnabled(item) && Fixture.states[originalProject] == .applied,
                  "inspection failure did not separate OFF intent from real file state")
        Fixture.failInspect=false
        try await mustFail("ON retry force-restored changed game files") { try await afterOffRestart.applyPatch(item,auth:auth) }
        try check(Fixture.restores==0 && Fixture.receipts[originalProject]==originalReceipt && !afterOffRestart.isPatchEnabled(item),
                  "blocked ON retry destroyed recovery evidence or silently forced restoration")
        Fixture.changed=false
        try await afterOffRestart.applyPatch(item,auth:auth)
        auth.authenticationRevision += 1
        afterOffRestart.recordPatchOffFailure(item,requestedRevision:inspectionRevision,auth:auth)
        try check(afterOffRestart.isPatchEnabled(item),"an old session error changed the newer session's requested state")

        // If a newer project is published, retire the old baseline safely first.
        Fixture.nextProject=PatchProject()
        let updatedProject=Fixture.nextProject.id
        try await afterOffRestart.applyPatch(item,auth:auth)
        try check(Fixture.states[originalProject] == .off && Fixture.states[updatedProject] == .applied,
                  "updated project did not safely restore previous history before applying")
        try check(Fixture.receipts[originalProject]==originalReceipt && Fixture.applies==originalApplies+1,
                  "updated project overwrote the original backup or recaptured twice")

        let recoveryRetry=afterOffRestart.recoveryItems.first { $0.projectID==updatedProject }!
        Fixture.failRestore=true
        try await mustFail("recovery OFF failure ignored") { try await afterOffRestart.restoreRecovery(recoveryRetry,auth:auth) }
        try check(!afterOffRestart.isPatchEnabled(item) && afterOffRestart.recoveryItems.first?.requestedEnabled==false,
                  "recovery failure did not publish OFF intent with retained recovery history")

        // Explicit OFF belongs to one transaction, not the whole catalog item
        // or project UUID. A sidecar repair keeps it; a new journal does not.
        try Fixture.reset()
        let bound=FeaturePatchService()
        try await bound.applyPatch(item,auth:auth)
        let boundProject=Fixture.nextProject.id,boundReceipt=Fixture.receipts[Fixture.nextProject.id]!
        Fixture.failRestore=true
        try await mustFail("binding fixture OFF failure ignored") { try await bound.restorePatch(item,auth:auth) }
        try check(!bound.isPatchEnabled(item),"bound OFF did not apply to its receipt")
        let unchangedSidecar=try Fixture.store.read(boundProject)!
        var repairedSidecar=unchangedSidecar
        repairedSidecar.phase = .recoveryRequired
        try Fixture.store.save(repairedSidecar)
        let repairedRestart=FeaturePatchService()
        try check(!repairedRestart.isPatchEnabled(item),"repair of the same journal sidecar reset requested OFF")
        try check(Fixture.receipts[boundProject]==boundReceipt,"switch binding changed its original receipt")
        try Fixture.establish(boundProject)
        try check(Fixture.receipts[boundProject]?.id != boundReceipt.id,"new transaction fixture reused its journal")
        try check(bound.isPatchEnabled(item),"in-memory old OFF leaked into a new journal for the same project")
        let newJournalRestart=FeaturePatchService()
        try check(newJournalRestart.isPatchEnabled(item),"persisted old OFF leaked into a new journal after restart")
        for key in Fixture.defaults.dictionaryRepresentation().keys { Fixture.defaults.removeObject(forKey:key) }
        try check(FeaturePatchService().isPatchEnabled(item),"old metadata-only OFF leaked into a new journal")

        // Migrate unbound build-39/40 intent once against the current receipt.
        try Fixture.reset()
        let legacy=FeaturePatchService(),legacyProject=UUID()
        try Fixture.establish(legacyProject);associate(legacy,item,legacyProject)
        Fixture.defaults.set(false,forKey:"patch_requested_enabled_catalog_1_fixture")
        try check(!legacy.isPatchEnabled(item),"legacy unbound OFF was reset during migration")
        let legacyBinding=Fixture.defaults.string(forKey:"patch_requested_binding_catalog_1_fixture")
        try check(legacyBinding?.contains(Fixture.receipts[legacyProject]!.id.uuidString)==true,
                  "legacy OFF was not bound to its current journal")
        try Fixture.establish(legacyProject)
        try check(legacy.isPatchEnabled(item),"migrated legacy OFF still leaked into the next journal")

        // AirLift has no backup journal: bind its explicit OFF to operation ID.
        try Fixture.reset()
        let airLift=FeaturePatchService(),airLiftProject=UUID()
        let firstAirLift=PatchEngineApplicationRecord(projectID:airLiftProject,engine:.airLift,
            baseline:.unavailable,targetKeys:["com.fixture.app\0Documents/file"],phase:.applied,totalBatches:1)
        try Fixture.store.save(firstAirLift);associate(airLift,item,airLiftProject)
        airLift.recordPatchOffFailure(item,requestedRevision:auth.authenticationRevision,auth:auth)
        try check(!airLift.isPatchEnabled(item),"AirLift operation OFF was not retained")
        try Fixture.store.save(firstAirLift)
        try check(!FeaturePatchService().isPatchEnabled(item),"same AirLift operation lost OFF after restart")
        let secondAirLift=PatchEngineApplicationRecord(projectID:airLiftProject,engine:.airLift,
            baseline:.unavailable,targetKeys:["com.fixture.app\0Documents/file"],phase:.applied,totalBatches:1)
        try Fixture.store.save(secondAirLift)
        try check(airLift.isPatchEnabled(item),"old AirLift OFF leaked into a different operation")
        try check(FeaturePatchService().isPatchEnabled(item),"persisted AirLift OFF leaked into a different operation")

        try Fixture.reset()
        let inventory=FeaturePatchService();try Fixture.establish(Fixture.nextProject.id);inventory.refreshRecoveryItems()
        try check(inventory.recoveryItems.count==1,"missing display metadata hid transaction")
        try Data("broken display metadata".utf8).write(to:Fixture.root.appendingPathComponent(".catalog-recovery.plist"))
        inventory.refreshRecoveryItems()
        try check(inventory.recoveryItems.count==1 && inventory.recoveryInventoryError != nil,"corrupt names hid valid journal/provenance")
        try check(inventory.patchApplicationState(item) == .recoveryRequired,"corrupt metadata downgraded catalog uncertainty to OFF")
        let recordPath=Fixture.root.appendingPathComponent(".engine-applications")
            .appendingPathComponent(Fixture.nextProject.id.uuidString+".plist")
        try Data("broken provenance".utf8).write(to:recordPath)
        inventory.refreshRecoveryItems()
        try check(inventory.recoveryItems.first?.state == .recoveryRequired,"corrupt provenance was hidden or displayed OFF")
        try await mustFail("corrupt provenance accepted recovery mutation") {
            try await inventory.restoreRecovery(inventory.recoveryItems[0],auth:auth)
        }
        try check(Fixture.restores==0,"corrupt provenance recovery wrote target")
        let saved=Fixture.root.appendingPathExtension("saved")
        try FileManager.default.moveItem(at:Fixture.root,to:saved)
        try Data([0]).write(to:Fixture.root)
        inventory.refreshRecoveryItems()
        try check(inventory.recoveryItems.count==1 && inventory.recoveryInventoryError != nil,"temporarily unreadable storage became empty/OFF")
        try FileManager.default.removeItem(at:Fixture.root);try FileManager.default.moveItem(at:saved,to:Fixture.root)
        print("Catalog recovery production methods: \(checks) checks passed")
    }
}
