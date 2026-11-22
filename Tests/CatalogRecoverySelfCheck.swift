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
        service.catalogApplications.associate(project,with:"catalog_\(item.id)_\(item.artifactVariant ?? "legacy")")
        service.catalogApplications.markApplied("catalog_\(item.id)_\(item.artifactVariant ?? "legacy")")
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

    @MainActor static func targetValidationChecks()async throws {
        func project(_ bundles:[String], declared:[String]? = nil) -> PatchProject {
            PatchProject(name:"Target fixture",bundleIdentifiers:declared ?? bundles,
                rules:bundles.map { PatchRule(bundleID:$0,relativePath:"Documents/shared-name",
                                             replacementFilename:"file",replacementData:Data([7])) })
        }
        func accept(_ candidate:PatchProject,variant:String = "generic",_ message:String)async throws {
            try Fixture.reset();Fixture.nextProject=candidate
            let service=FeaturePatchService(),auth=AuthManager()
            let item=PatchItem(id:30,name:"Targets",slug:"targets",artifactVariant:variant)
            service.adoptVerifiedCatalogForFixture([30:[variant]])
            try await service.applyPatch(item,auth:auth)
            try check(Fixture.prepares==1 && Set(Fixture.preparedBundleIDs)==Set(candidate.allBundleIdentifiers),
                      message+": preparation lost or added an application identity")
            try check(Fixture.applies==1 && service.isPatchEnabled(item),message+": apply did not complete")
        }
        func reject(_ candidate:PatchProject,variant:String = "generic",_ message:String)async throws {
            try Fixture.reset();Fixture.nextProject=candidate
            let service=FeaturePatchService(),auth=AuthManager()
            let item=PatchItem(id:30,name:"Targets",slug:"targets",artifactVariant:variant)
            service.adoptVerifiedCatalogForFixture([30:[variant]])
            let oldProject=UUID();try Fixture.establish(oldProject);associate(service,item,oldProject)
            do { try await service.applyPatch(item,auth:auth);throw CatalogCheckError.failed(message+": accepted") }
            catch let failure as PatchOperationError {
                try check(failure.stage == .target,message+": did not fail at target validation")
            }
            try check(Fixture.prepares==0 && Fixture.applies==0 && Fixture.restores==0,
                      message+": prepared, restored or wrote before rejecting targets")
            try check(!service.isPatchEnabled(item) && Fixture.states[oldProject] == .applied,
                      message+": failure lost OFF intent or changed the existing backup")
        }

        for (variant,bundle) in [("ffth","com.dts.freefireth"),("ffmax","com.dts.freefiremax"),
                                 ("capcut","com.lemon.lvoverseas")] {
            try await accept(project([bundle]),variant:variant,"legacy "+variant)
            try await accept(project(["com.example.other"]),variant:variant,"package binding overrides catalog label "+variant)
        }
        try await accept(project(["com.dts.freefireth"]),"generic known application")
        try await accept(project(["com.example.New-App"]),"generic arbitrary application")
        try await accept(project(["com.example.one","org.example.two"]),"generic multiple applications")
        try await accept(project(["com.example.one","org.example.two"],declared:[]),"inferred rule identities")
        try await accept(project(["com.example.one"],declared:["com.example.one","org.example.two"]),
                         "declared application without a replacement rule")
        for variant in ["ffth", "ffmax", "capcut"] {
            try await accept(project(["com.example.custom", "org.example.second"]), variant: variant,
                             "package targets preserved independently of catalog label " + variant)
        }
        try await accept(project((0..<256).map { "com.example.app\($0)" }),"maximum 256 applications")

        for variant in ["unknown","native","mod","original",""] {
            try await reject(project(["com.example.one"]),variant:variant,"unsupported variant "+variant)
        }
        for bundle in ["", "com.example..app", " com.example.app", "com.example.app ",
                       "com.example/app", "com.example_unsafe", "com.exämple.app", "com.example.-app",
                       UUID().uuidString, "com.example.app\n", String(repeating:"x",count:250)+".example"] {
            try await reject(project([bundle]),"noncanonical identity "+bundle)
        }
        try await reject(project([]),"empty target project")
        var declarationOnly=project(["com.example.one"]);declarationOnly.rules=[]
        try await reject(declarationOnly,"declarations without a patch rule")
        try await reject(project((0..<257).map { "com.example.app\($0)" }),"more than 256 applications")
        try await reject(project(["com.example.one"],declared:["org.example.other"]),"rule not declared")
        try await reject(project(["com.example.one"],declared:["com.example.one","com.example.one"]),
                         "duplicate declaration")
        var invalidDirectory=project(["com.example.one"])
        invalidDirectory.directories=[PatchDirectory(bundleID:"org.example.other",relativePath:"Documents/new")]
        try await reject(invalidDirectory,"directory not declared")
        for kind in ["appGroup","systemAppGroup","system","native","Application",""] {
            var invalid=project(["com.example.one"]);invalid.rules[0].containerKind=kind
            try await reject(invalid,"unsupported rule container "+kind)
            invalid=project(["com.example.one"])
            invalid.directories=[PatchDirectory(bundleID:"com.example.one",relativePath:"Documents/new",containerKind:kind)]
            try await reject(invalid,"unsupported directory container "+kind)
        }
        var explicitApplication=project(["com.example.one"])
        explicitApplication.rules[0].containerKind="application"
        explicitApplication.directories=[PatchDirectory(bundleID:"com.example.one",relativePath:"Documents/new",containerKind:"application")]
        try await accept(explicitApplication,"explicit application containers")
        for path in ["../escape","/Documents/file","Documents/../file","Documents\\file"," Documents/file"] {
            var invalid=project(["com.example.one"]);invalid.rules[0].relativePath=path
            try await reject(invalid,"noncanonical rule path "+path)
        }
        var collision=project(["com.example.one"]);collision.rules.append(collision.rules[0])
        try await reject(collision,"duplicate application target")
        collision=project(["com.example.one"])
        collision.directories=[PatchDirectory(bundleID:"com.example.one",relativePath:collision.rules[0].relativePath)]
        try await reject(collision,"file and directory target collision")

        // These are the production Codable project/rule/directory types used by
        // PatchPackageCodec's payload decoder, not simplified fixture models.
        var supplied=explicitApplication;supplied.rules[0].containerKind="appGroup"
        supplied.directories[0].containerKind="systemAppGroup"
        let encoded=try PropertyListEncoder().encode(supplied)
        let decoded=try PropertyListDecoder().decode(PatchProject.self,from:encoded)
        try check(decoded.rules[0].containerKind=="appGroup" && decoded.directories[0].containerKind=="systemAppGroup",
                  "package model silently discarded non-application container metadata")
        try await reject(decoded,"decoded non-application metadata")
        let legacyDecoded=try PropertyListDecoder().decode(PatchProject.self,from:PropertyListEncoder().encode(project(["com.example.one"])))
        try check(legacyDecoded.rules[0].containerKind==nil,"old package without kind stopped decoding")
    }

    @MainActor static func retiredVariantChecks()async throws {
        let old=PatchItem(id:44,name:"Original",slug:"original",artifactVariant:"ffth")
        let current=PatchItem(id:44,name:"Generic",slug:"replacement",artifactVariant:"generic")
        let unrelated=PatchItem(id:45,name:"Other",slug:"other",artifactVariant:"ffth")
        let oldIdentity="catalog_44_ffth"
        func clearPreferences() {
            for key in Fixture.defaults.dictionaryRepresentation().keys { Fixture.defaults.removeObject(forKey:key) }
        }
        func seed()async throws -> UUID {
            let initial=FeaturePatchService()
            try await initial.applyPatch(old,auth:AuthManager())
            return Fixture.nextProject.id
        }

        try Fixture.reset()
        let oldID=try await seed(),receiptID=Fixture.receipts[Fixture.nextProject.id]!.id
        clearPreferences()
        let restarted=FeaturePatchService(),auth=AuthManager()
        try check(restarted.patchApplicationState(current) == .off,"unverified catalog adopted retired variant")
        let downloadsBeforeProof=Fixture.downloads
        try await mustFail("unverified generic catalog applied") { try await restarted.applyPatch(current,auth:auth) }
        try await mustFail("unverified generic catalog inspected a backup") { _ = try await restarted.inspectPatchRestore(current,auth:auth) }
        try await mustFail("unverified generic catalog restored a backup") { try await restarted.restorePatch(current,auth:auth) }
        try check(Fixture.downloads==downloadsBeforeProof && Fixture.applies==1 && Fixture.restores==0,
                  "missing catalog proof downloaded or mutated files")
        restarted.adoptVerifiedCatalogForFixture([44:["generic"]],revision:0)
        try await mustFail("generic catalog proof from another session applied") { try await restarted.applyPatch(current,auth:auth) }
        try await mustFail("generic catalog proof from another session restored") { try await restarted.restorePatch(current,auth:auth) }
        try check(Fixture.downloads==downloadsBeforeProof && Fixture.restores==0,"stale catalog proof crossed session")
        restarted.adoptVerifiedCatalogForFixture([44:["generic"]])
        try check(restarted.patchApplicationState(current) == .applied,
                  "retired variant backup inaccessible after preference loss")
        try check(!restarted.isPatchEnabled(current),"rejected ON request lost its OFF intent after fresh proof")
        let review=try await restarted.inspectPatchRestore(current,auth:auth)
        try check(review.projectID==oldID && review.receiptID==receiptID,"generic OFF inspected another backup")
        Fixture.failRestore=true
        try await mustFail("retired OFF failure ignored") { try await restarted.restorePatch(current,auth:auth) }
        try check(!restarted.isPatchEnabled(current) && Fixture.states[oldID] == .applied,
                  "retired OFF failure lost intent or backup")
        let metadata=try PropertyListSerialization.propertyList(
            from:Data(contentsOf:Fixture.root.appendingPathComponent(".catalog-recovery.plist")),format:nil) as! [[String:Any]]
        try check(metadata.first?["catalogIdentity"] as? String == oldIdentity &&
                  metadata.first?["requestedEnabled"] as? Bool == false,
                  "retired OFF was not persisted on the original durable row")
        clearPreferences()
        let afterOffRestart=FeaturePatchService();afterOffRestart.adoptVerifiedCatalogForFixture([44:["generic"]])
        try check(!afterOffRestart.isPatchEnabled(current),"retired OFF intent lost across restart")
        Fixture.failRestore=false
        try await afterOffRestart.restorePatch(current,auth:auth)
        try check(Fixture.restores==1 && Fixture.states[oldID] == .off,"generic OFF did not restore retired variant")

        try Fixture.reset()
        let retryID=try await seed(),retryReceipt=Fixture.receipts[Fixture.nextProject.id]!.id
        let retry=FeaturePatchService();retry.adoptVerifiedCatalogForFixture([44:["generic"]])
        try await retry.applyPatch(current,auth:auth)
        try check(Fixture.applies==1 && Fixture.restores==0 && Fixture.receipts[retryID]?.id==retryReceipt,
                  "generic same-package retry recaptured a patched baseline")
        try check(retry.isPatchEnabled(current),"generic retry did not retain enabled intent")

        try Fixture.reset()
        let replacedID=try await seed()
        Fixture.nextProject=PatchProject()
        let replacementID=Fixture.nextProject.id
        let replacement=FeaturePatchService();replacement.adoptVerifiedCatalogForFixture([44:["generic"]])
        try await replacement.applyPatch(current,auth:auth)
        try check(Fixture.restores==1 && Fixture.applies==2 && Fixture.states[replacedID] == .off &&
                  Fixture.states[replacementID] == .applied,"generic replacement did not restore retired baseline first")

        try Fixture.reset()
        let changedID=try await seed()
        Fixture.nextProject=PatchProject();Fixture.changed=true
        let changed=FeaturePatchService();changed.adoptVerifiedCatalogForFixture([44:["generic"]])
        try await mustFail("changed retired targets overwritten without review") { try await changed.applyPatch(current,auth:auth) }
        try check(Fixture.restores==0 && Fixture.applies==1 && !changed.isPatchEnabled(current),
                  "changed retired retry mutated files or ignored OFF intent")
        let changedReview=try await changed.inspectPatchRestore(current,auth:auth)
        try check(changedReview.projectID==changedID && !changedReview.changedPaths.isEmpty,
                  "existing confirmation cannot review retired receipt")
        Fixture.changed=false
        try await changed.applyPatch(current,auth:auth,recoveryConfirmation:changedReview)
        try check(Fixture.restores==1 && Fixture.applies==2,"confirmed retired retry did not restore then apply")

        try Fixture.reset()
        let siblingID=try await seed()
        let sibling=FeaturePatchService();sibling.adoptVerifiedCatalogForFixture([44:["ffth","generic"]])
        try check(sibling.patchApplicationState(current) == .off && sibling.patchApplicationState(old) == .applied,
                  "still-published legacy sibling was stolen by generic")
        try await mustFail("generic restore stole still-published legacy sibling") { try await sibling.restorePatch(current,auth:auth) }
        try check(Fixture.states[siblingID] == .applied && Fixture.restores==0,"sibling restore mutated original")

        try Fixture.reset()
        let outsider=FeaturePatchService()
        try await outsider.applyPatch(unrelated,auth:auth)
        let outsiderID=Fixture.nextProject.id
        outsider.adoptVerifiedCatalogForFixture([44:["generic"],45:["ffth"]])
        try check(outsider.patchApplicationState(current) == .off,"another catalog ID was adopted")
        try await mustFail("generic restored unrelated catalog ID") { try await outsider.restorePatch(current,auth:auth) }
        try check(Fixture.states[outsiderID] == .applied && Fixture.restores==0,"unrelated restore mutated files")

        try Fixture.reset()
        _ = try await seed()
        Fixture.nextProject=PatchProject()
        Fixture.nextProject.bundleIdentifiers=["com.dts.freefiremax"]
        Fixture.nextProject.rules[0].bundleID="com.dts.freefiremax"
        let second=FeaturePatchService()
        try await second.applyPatch(PatchItem(id:44,name:"Second",slug:"second",artifactVariant:"ffmax"),auth:auth)
        clearPreferences()
        let ambiguous=FeaturePatchService();ambiguous.adoptVerifiedCatalogForFixture([44:["generic"]])
        let downloads=Fixture.downloads,applies=Fixture.applies
        try check(ambiguous.patchApplicationState(current) == .recoveryRequired && !ambiguous.isPatchEnabled(current),
                  "multiple retired active backups selected arbitrarily")
        try await mustFail("ambiguous retired apply selected a backup") { try await ambiguous.applyPatch(current,auth:auth) }
        try await mustFail("ambiguous retired restore selected a backup") { try await ambiguous.restorePatch(current,auth:auth) }
        try check(Fixture.downloads==downloads && Fixture.applies==applies && Fixture.restores==0,
                  "ambiguous retired operation downloaded or changed files")
        ambiguous.adoptVerifiedCatalogForFixture([:])
        try check(ambiguous.patchApplicationState(current) == .off,"cleared catalog proof kept retired aliases")
    }
    @MainActor static func main()async throws {
        let item=PatchItem(id:1,name:"Feature\nOne",slug:"fixture")
        try Fixture.reset()
        let service=FeaturePatchService(),auth=AuthManager(),oldID=UUID()
        try Fixture.establish(oldID);associate(service,item,oldID)
        let oldReceipt=Fixture.receipts[oldID]
        Fixture.failApply=true
        try await mustFail("failed replacement ignored") { try await service.applyPatch(item,auth:auth) }
        try check(service.catalogApplications.projectID(for:"catalog_1_ffth")==oldID,"active association replaced")
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
        try check(Fixture.applies==0 && incoming.catalogApplications.projectID(for:"catalog_1_ffth")==nil,
                  "incoming active project mutated a new catalog association")

        try Fixture.reset()
        let first=FeaturePatchService();Fixture.failApply=true
        try await mustFail("pre-journal failure ignored") { try await first.applyPatch(item,auth:auth) }
        try check(first.catalogApplications.projectID(for:"catalog_1_ffth")==nil,"uncommitted association not removed")
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
            ["projectID":a.uuidString,"title":"A","catalogIdentity":"catalog_1_ffth"],
            ["projectID":b.uuidString,"title":"B","catalogIdentity":"catalog_1_ffth"]]
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
        try check(partial.catalogApplications.projectID(for:"catalog_1_ffth")==Fixture.nextProject.id,"partial journal lost association")
        try check(partial.recoveryItems.first?.state == .recoveryRequired,"partial write advertised OFF")

        try Fixture.reset()
        let changed=FeaturePatchService();try Fixture.establish(Fixture.nextProject.id);associate(changed,item,Fixture.nextProject.id)
        Fixture.changed=true
        try await mustFail("default OFF overwrote changed targets") { try await changed.restorePatch(item,auth:auth) }
        try check(Fixture.restores==0 && changed.isPatchApplied(item),"changed-target refusal lost ON or restored data")
        let review=try await changed.inspectPatchRestore(item,auth:auth)
        try check(review.changedPaths==["com.dts.freefireth/Documents/file"],"inspection did not provide changed paths")
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
                  "a second ON request was admitted while the original operation remained active")
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
        try await mustFail("ON after failed OFF bypassed pending recovery") { try await afterOffRestart.applyPatch(item,auth:auth) }
        try check(!afterOffRestart.isPatchEnabled(item) && Fixture.applies==originalApplies,
                  "blocked ON after failed OFF changed application or intent")
        try await afterOffRestart.restorePatch(item,auth:auth)
        try await afterOffRestart.applyPatch(item,auth:auth)
        try check(afterOffRestart.isPatchEnabled(item) && Fixture.applies==originalApplies+1,
                  "explicit restore did not clear pending recovery before ON")
        try check(Fixture.receipts[originalProject] != originalReceipt &&
                  FileManager.default.fileExists(atPath: originalReceipt.journalURL.path),
                  "explicit restore/reapply did not create a new receipt while retaining the old journal")

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
        let restoresBeforeBlocked = Fixture.restores
        try await mustFail("ON retry force-restored changed game files") { try await afterOffRestart.applyPatch(item,auth:auth) }
        let currentReceipt=Fixture.receipts[originalProject]!
        try check(Fixture.restores==restoresBeforeBlocked && Fixture.receipts[originalProject]==currentReceipt &&
                  currentReceipt.id != originalReceipt.id && !afterOffRestart.isPatchEnabled(item),
                  "blocked ON retry destroyed recovery evidence or silently forced restoration")
        Fixture.changed=false
        try await afterOffRestart.restorePatch(item,auth:auth)
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
        try check(Fixture.receipts[originalProject] != nil &&
                  FileManager.default.fileExists(atPath: originalReceipt.journalURL.path),
                  "updated project overwrote or discarded the original backup")

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
        Fixture.defaults.set(false,forKey:"patch_requested_enabled_catalog_1_ffth")
        try check(!legacy.isPatchEnabled(item),"legacy unbound OFF was reset during migration")
        let legacyBinding=Fixture.defaults.string(forKey:"patch_requested_binding_catalog_1_ffth")
        try check(legacyBinding?.contains(Fixture.receipts[legacyProject]!.id.uuidString)==true,
                  "legacy OFF was not bound to its current journal")
        try Fixture.establish(legacyProject)
        try check(legacy.isPatchEnabled(item),"migrated legacy OFF still leaked into the next journal")

        // AirLift has no backup journal: bind its explicit OFF to operation ID.
        try Fixture.reset()
        let airLift=FeaturePatchService(),airLiftProject=UUID()
        let firstAirLift=PatchEngineApplicationRecord(projectID:airLiftProject,engine:.airLift,
            baseline:.unavailable,targetKeys:["com.dts.freefireth\0Documents/file"],phase:.applied,totalBatches:1)
        try Fixture.store.save(firstAirLift);associate(airLift,item,airLiftProject)
        airLift.recordPatchOffFailure(item,requestedRevision:auth.authenticationRevision,auth:auth)
        try check(!airLift.isPatchEnabled(item),"AirLift operation OFF was not retained")
        try Fixture.store.save(firstAirLift)
        try check(!FeaturePatchService().isPatchEnabled(item),"same AirLift operation lost OFF after restart")
        let secondAirLift=PatchEngineApplicationRecord(projectID:airLiftProject,engine:.airLift,
            baseline:.unavailable,targetKeys:["com.dts.freefireth\0Documents/file"],phase:.applied,totalBatches:1)
        try Fixture.store.save(secondAirLift)
        try check(airLift.isPatchEnabled(item),"old AirLift OFF leaked into a different operation")
        try check(FeaturePatchService().isPatchEnabled(item),"persisted AirLift OFF leaked into a different operation")

        // A failed OFF must not strand a changed target behind an OFF toggle.
        // Inspection is read-only; the existing review can authorize only its
        // exact receipt/snapshot and the verified retry remains one operation.
        try Fixture.reset()
        let retryChanged=FeaturePatchService()
        try await retryChanged.applyPatch(item,auth:auth)
        let retryProject=Fixture.nextProject.id,retryReceipt=Fixture.receipts[Fixture.nextProject.id]!
        Fixture.failRestore=true
        try await mustFail("OFF failure was not reported") { try await retryChanged.restorePatch(item,auth:auth) }
        Fixture.failRestore=false;Fixture.changed=true
        do {
            try await retryChanged.applyPatch(item,auth:auth)
            throw CatalogCheckError.failed("unconfirmed changed target was silently replaced")
        } catch {
            try check(PatchRestoreError.requiresRestoreReview(error),"ON retry did not identify the existing review route")
        }
        let retryReview=try await retryChanged.inspectPatchRestore(item,auth:auth)
        try check(!retryReview.changedPaths.isEmpty && !retryChanged.isPatchEnabled(item),"opening retry review changed OFF intent")
        try check(Fixture.restores==0 && Fixture.receipts[retryProject]==retryReceipt,"inspection/cancel touched the original receipt")
        let originalSnapshot=Fixture.snapshot
        Fixture.snapshot=Data([9,8,7])
        try await mustFail("stale retry snapshot reached restore/apply") {
            try await retryChanged.applyPatch(item,auth:auth,recoveryConfirmation:retryReview)
        }
        try check(Fixture.restores==0 && Fixture.applies==1 && !retryChanged.isPatchEnabled(item),"stale retry mutated files or enabled toggle")
        Fixture.snapshot=originalSnapshot
        let sessionReview=try await retryChanged.inspectPatchRestore(item,auth:auth)
        auth.authenticationRevision += 1
        try await mustFail("retry confirmation crossed auth revision") {
            try await retryChanged.applyPatch(item,auth:auth,recoveryConfirmation:sessionReview)
        }
        try check(Fixture.restores==0 && Fixture.applies==1,"old-session retry reached mutation")
        let freshRetryReview=try await retryChanged.inspectPatchRestore(item,auth:auth)
        try await retryChanged.applyPatch(item,auth:auth,recoveryConfirmation:freshRetryReview)
        try check(Fixture.restores==1 && Fixture.forcedRestore && Fixture.applies==2,"confirmed retry did not restore old bytes before fresh apply")
        try check(retryChanged.isPatchEnabled(item) && Fixture.receipts[retryProject]?.id != retryReceipt.id,"confirmed retry did not publish a new verified application")
        try check(FileManager.default.fileExists(atPath:retryReceipt.journalURL.path),"confirmed retry deleted old recovery evidence")
        try check(!retryChanged.patchOperationInProgress,"confirmed retry retained the shared busy state")
        // A review for a receipt that has already been retired cannot silently
        // become a fresh ON request without validating its old transaction.
        let newReceipt=Fixture.receipts[retryProject]!
        try await mustFail("old receipt review was reused after successful reapply") {
            try await retryChanged.applyPatch(item,auth:auth,recoveryConfirmation:freshRetryReview)
        }
        try check(Fixture.receipts[retryProject]==newReceipt && Fixture.applies==2,"old retry review replaced a later baseline")

        // Import the exact reference OFF key only for its still-active binding.
        // This is a one-time hint; a subsequent user request/new receipt wins.
        try Fixture.reset()
        let refOFF=FeaturePatchService(),refProject=UUID()
        try Fixture.establish(refProject);associate(refOFF,item,refProject)
        let refBinding=refProject.uuidString+":journal:"+Fixture.receipts[refProject]!.id.uuidString
        Fixture.defaults.set(refBinding,forKey:"patch_applied_catalog_1_ffth_disabledBinding")
        Fixture.defaults.set(true,forKey:"patch_applied_catalog_1_ffth_recovery")
        try check(!refOFF.isPatchEnabled(item),"reference OFF binding displayed ON")
        try check(Fixture.defaults.string(forKey:"patch_requested_binding_catalog_1_ffth")==refBinding,
                  "reference recovery preference prevented bound-OFF migration")
        try check(FeaturePatchService().isPatchEnabled(item)==false,"reference OFF migration did not survive restart")
        for key in Fixture.defaults.dictionaryRepresentation().keys { Fixture.defaults.removeObject(forKey:key) }
        let importedAfterLoss=FeaturePatchService()
        try check(!importedAfterLoss.isPatchEnabled(item),"migrated reference OFF disappeared after preference loss")
        try check(importedAfterLoss.recoveryItems.isEmpty || Fixture.receipts[refProject] != nil,"reference migration changed recovery state")
        try Fixture.establish(refProject)
        try check(FeaturePatchService().isPatchEnabled(item),"reference OFF binding leaked into a later receipt")

        try Fixture.reset()
        let wrongReference=FeaturePatchService(),wrongProject=UUID()
        try Fixture.establish(wrongProject);associate(wrongReference,item,wrongProject)
        Fixture.defaults.set(wrongProject.uuidString+":journal:"+UUID().uuidString,
                             forKey:"patch_applied_catalog_1_ffth_disabledBinding")
        try check(wrongReference.isPatchEnabled(item),"stale reference OFF was moved to a new receipt")

        try Fixture.reset()
        let slugReference=FeaturePatchService(),slugProject=UUID()
        try Fixture.establish(slugProject)
        slugReference.catalogApplications.associate(slugProject,with:"fixture_ffth")
        slugReference.catalogApplications.markApplied("fixture_ffth")
        let slugBinding=slugProject.uuidString+":journal:"+Fixture.receipts[slugProject]!.id.uuidString
        Fixture.defaults.set(slugBinding,forKey:"patch_applied_fixture_ffth_disabledBinding")
        try check(!slugReference.isPatchEnabled(item),"slug reference OFF did not migrate to stable catalog identity")
        try check(slugReference.catalogApplications.projectID(for:"catalog_1_ffth")==slugProject,"reference migration lost project association")
        try Fixture.establish(slugProject)
        try check(FeaturePatchService().isPatchEnabled(item),"old slug OFF leaked to a later transaction")

        try Fixture.reset()
        let referenceAirLift=FeaturePatchService(),referenceAirLiftID=UUID()
        let referenceOperation=PatchEngineApplicationRecord(projectID:referenceAirLiftID,engine:.airLift,
            baseline:.unavailable,targetKeys:["com.dts.freefireth\0Documents/file"],phase:.applied,totalBatches:1)
        try Fixture.store.save(referenceOperation);associate(referenceAirLift,item,referenceAirLiftID)
        let operationBinding=referenceAirLiftID.uuidString+":operation:"+referenceOperation.operationID.uuidString
        Fixture.defaults.set(operationBinding,forKey:"patch_applied_catalog_1_ffth_disabledBinding")
        try check(!referenceAirLift.isPatchEnabled(item),"reference AirLift operation OFF did not migrate")
        let nextOperation=PatchEngineApplicationRecord(projectID:referenceAirLiftID,engine:.airLift,
            baseline:.unavailable,targetKeys:["com.dts.freefireth\0Documents/file"],phase:.applied,totalBatches:1)
        try Fixture.store.save(nextOperation)
        try check(FeaturePatchService().isPatchEnabled(item),"reference AirLift OFF migrated to another operation")

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
        print("Catalog recovery prior behavior: \(checks) checks passed")
        try await targetValidationChecks()
        try await retiredVariantChecks()
        print("Catalog recovery and package targets production methods: \(checks) checks passed")
    }
}
