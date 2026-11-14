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
        try await mustFail("active receipt allowed catalog replacement") { try await service.applyPatch(item,auth:auth) }
        try check(service.catalogApplications.projectID(for:"catalog_1_fixture")==oldID,"active association replaced")
        try check(Fixture.receipts[oldID]==oldReceipt && Fixture.downloads==0,"active backup altered or redundant download started")
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
        try check(Set(rows[0].keys)==Set(["projectID","title","catalogIdentity"]),"recovery metadata contains payload/auth/URL fields")
        for key in Fixture.defaults.dictionaryRepresentation().keys { Fixture.defaults.removeObject(forKey:key) }
        let restarted=FeaturePatchService();restarted.refreshRecoveryItems()
        try check(restarted.recoveryItems.count==1 && restarted.recoveryItems[0].title=="FeatureOne","restart or preference loss hid durable recovery")
        try check(restarted.patchApplicationState(item) == .applied,"preference loss made the main catalog card display OFF")
        let recoveredCatalogReview=try await restarted.inspectPatchRestore(item,auth:auth)
        try check(recoveredCatalogReview.projectID==projectID,"main catalog inspection did not recover the durable project identity")
        Fixture.nextProject=PatchProject()
        let downloadsBeforeRetry=Fixture.downloads
        try await mustFail("preference loss permitted a new project for an active catalog identity") {
            try await restarted.applyPatch(item,auth:auth)
        }
        try check(Fixture.downloads==downloadsBeforeRetry,"lost-preference retry downloaded a replacement for an active identity")
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
        try check(successes==1 && refusals==1 && Fixture.applies==1 && Fixture.downloads==1,
                  "two queued ON requests applied more than once or replaced the active project")
        try check(!concurrent.patchOperationInProgress,"completed queue retained busy state")

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
