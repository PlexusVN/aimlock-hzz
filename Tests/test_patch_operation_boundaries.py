"""Run production startup ordering and transaction identity boundary bodies."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function

ROOT = Path(__file__).resolve().parents[1]


def swift_tools():
    native = shutil.which('swiftc')
    if native:
        return [native], str, lambda p: [str(p)]
    distro = os.environ.get('ASTRA_SWIFT_WSL_DISTRIBUTION')
    if os.name == 'nt' and distro:
        native = subprocess.check_output(['wsl', '-d', distro, '--', 'bash', '-lc', 'command -v swiftc'], text=True).strip()
        def translate(p):
            value = str(Path(p).resolve()).replace('\\', '/')
            return '/mnt/' + value[0].lower() + value[2:]
        return ['wsl', '-d', distro, '--', native], translate, lambda p: ['wsl', '-d', distro, '--', translate(p)]
    raise unittest.SkipTest('requires Swift; ASTRA_SWIFT_WSL_DISTRIBUTION enables Windows checks')


class PatchOperationBoundaries(unittest.TestCase):
    def execute(self, code, fixture):
        compiler, translate, command = swift_tools()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'ActualBoundary.swift'
            source.write_text(code, encoding='utf-8')
            binary = Path(directory) / 'boundary-check'
            subprocess.run(compiler + ['-swift-version', '5', translate(source),
                translate(ROOT / 'Tests' / fixture), '-o', translate(binary)], check=True)
            subprocess.run(command(binary), check=True)

    def test_direct_probe_completes_before_automatic_native_attempt(self):
        source = (ROOT / 'ThreeOneOSFive/App.swift').read_text(encoding='utf-8')
        code = '''import Foundation
func log(_ text: String) {}
enum ProbeStatus { case idle, success, failed
 var isSuccess: Bool { self == .success }; var isFailed: Bool { self == .failed }
}
final class Probe {
 var hasDirectDirectoryAccess=false, isCheckingDirectAccess=false, didCheckDirectAccess=false
 var hasSandboxAccess=false, kernelExploitRunning=false, autoRunAttempted=false
 var kernelExploitApplicable=true, attempts=0
 var exploitStatus=ProbeStatus.idle
 func runKernelExploitIfNeeded() { attempts += 1 }
 func consider() { maybeAutoRunKernelExploit() }
 func finish(_ available: Bool) { completeDirectAccessProbe(available) }
'''
        for signature in ['private func completeDirectAccessProbe(', 'private func maybeAutoRunKernelExploit(']:
            code += extract_function(source, signature) + '\n'
        code += '}\n'
        self.execute(code, 'DirectProbeOrderingSelfCheck.swift')

    def test_transaction_reidentifies_container_under_retained_grant(self):
        source = (ROOT / 'ThreeOneOSFive/helpers/PatchTransaction.swift').read_text(encoding='utf-8')
        code = '''import Foundation
enum Failure: Error { case denied }
enum PatchPackageError: Error { case targetAppUnavailable(String) }
enum WorseQueryError: Error { case appGroupUnavailable }
enum DirectPatchExecutionContext { static func check() throws {} }
enum ExploitSupportPolicy { enum Provider { case legacy3105, worseQuery }
 static var currentAccessProvider = Provider.worseQuery
}
enum Calls {
 static var released:[Int64]=[], invalidated:[String]=[], identities:[String:String]=[:]
 static var mcmPaths:[String:String]=[:], lsPaths:[String:String]=[:], conflict=false
 static var events:[String]=[], unreadable=Set<String>(), operationRan=false
 static var next:Int64=0
 static func reset() { released=[]; invalidated=[]; identities=[:]; mcmPaths=[:]; lsPaths=[:]; conflict=false; events=[]; unreadable=[]; operationRan=false; next=0 }
}
func sandbox_extension_release_handle(_ value:Int64) { Calls.released.append(value) }
enum WorseQueryHelper {
 static var isAvailable:Bool { ExploitSupportPolicy.currentAccessProvider == .worseQuery }
 static func acquireAccess(for path:String) throws -> Int64 { Calls.next += 1; Calls.events.append("grant:"+path); return Calls.next }
}
enum ContainerStore {
 static func resolveAppContainerForPatch(bundleID:String) throws -> String { "/owned/"+bundleID }
 static func isApplicationContainerPath(_ path:String)->Bool { path.hasPrefix("/owned/") }
 static func grantContainerAccess(_ path:String)->Int64 { Calls.next += 1; return Calls.next }
 static func readWorseQueryIdentity(_ path:String)->(identifier:String?,readable:Bool,diagnostics:[String]) {
  Calls.events.append("identity:"+path)
  return (Calls.identities[path],!Calls.unreadable.contains(path),Calls.conflict ? ["identity=conflict"] : [])
 }
'''
        store = (ROOT / 'ThreeOneOSFive/helpers/ContainerStore.swift').read_text(encoding='utf-8')
        code += extract_function(store, 'static func validateWorseQueryTransactionIdentity(')
        code += '''
}
func MCMContainerPathForWorseQuery(_ cls:UInt64,_ id:String,_ group:Bool,_ error:UnsafeMutablePointer<NSString?>?)->String? {
 Calls.events.append("mcm:"+id); return Calls.mcmPaths[id]
}
func containerPathForBundleID(_ id:String)->String? { Calls.events.append("ls:"+id); return Calls.lsPaths[id] }
enum ContainerDiscoveryMerger { static func canonicalPath(_ path:String)->String { path } }
enum IOS27ContainerSession { static func invalidate(bundleIDs:[String]) { Calls.invalidated += bundleIDs } }
enum PatchPathValidator {
 static func canonicalFileURL(_ url:URL)->URL { url }
 static func canonicalBundleIdentifier(_ value:String)throws->String { value }
}
enum Service {
 static func execute(_ ids:[String]) throws {
  try withResolvedContainers(bundleIDs:ids) { _ in Calls.operationRan=true }
 }
'''
        code += extract_function(source, 'private static func withResolvedContainers<T>(') + '\n}\n'
        self.execute(code, 'ContainerCommitIdentitySelfCheck.swift')


if __name__ == '__main__':
    unittest.main()
