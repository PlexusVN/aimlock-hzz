import Foundation

@main struct GenericPackageTargetSelfCheck {
    enum Failure:Error { case failed(String) }
    static func require(_ value:Bool,_ message:String)throws {
        if !value { throw Failure.failed(message) }
    }
    static func main()throws {
        let service=FeaturePatchService()
        var project=PatchProject(name:"Generic codec target fixture",bundleIdentifiers:["com.example.app"],
            directories:[PatchDirectory(bundleID:"com.example.app",relativePath:"Documents/new")],
            rules:[PatchRule(bundleID:"com.example.app",relativePath:"Documents/file",
                             replacementFilename:"file",replacementData:Data([0,1,2]))])
        let encoded=try PatchPackageCodec.encodeNew(project:project,password:nil)
        let legacy=try PatchPackageCodec.decode(encoded.data,password:nil).project
        try require(legacy.rules[0].containerKind==nil && legacy.directories[0].containerKind==nil,
                    "old application package without containerKind stopped decoding")
        try service.validate(legacy,variant:"generic")
        var checks=3
        for kind in ["application","appGroup","systemAppGroup","system","native",""] {
            project.rules[0].containerKind=kind;project.directories[0].containerKind=kind
            let package=try PatchPackageCodec.encodeNew(project:project,password:nil)
            let decoded=try PatchPackageCodec.decode(package.data,password:nil).project
            try require(decoded.rules[0].containerKind==kind && decoded.directories[0].containerKind==kind,
                        "real codec discarded target container kind "+kind)
            checks += 1
            if kind == "application" {
                try service.validate(decoded,variant:"generic")
            } else {
                do {
                    try service.validate(decoded,variant:"generic")
                    throw Failure.failed("generic accepted target container kind "+kind)
                } catch ProtectedDownloadError.invalidResponse {}
            }
            checks += 1
        }
        print("Actual encrypted codec application target policy: \(checks) checks passed")
    }
}
