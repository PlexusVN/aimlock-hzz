"""Run actual catalog/gate/inventory methods with isolated transport boundaries."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function

ROOT = Path(__file__).resolve().parents[1]
METHODS = [
    'func applyPatch(', 'private func applyPatchInOperation(',
    'private func validateCatalogPackageTargets(',
    'func inspectPatchRestore(', 'func inspectRecoveryRestore(',
    'func restorePatch(', 'func restoreRecovery(',
    'private func withAuthenticatedPatchOperation<', 'private func catalogProjectID(',
    'private func activeCatalogProjectIDs(',
    'private func catalogLookupIdentities(',
    'private func requireCurrentCatalogForGeneric(',
    'private func restorePatchInOperation(', 'private func restoreReceipt(',
    'private func inspectProjectRestore(', 'private func restoreProjectInOperation(',
    'private func beginPatchOperation(', 'private func endPatchOperation(',
    'private func recoveryMetadataURL(', 'private func readRecoveryMetadata(',
    'private func saveRecoveryMetadata(', 'func refreshRecoveryItems(',
    'private func writeRecoveryMetadata(', 'private func setRequestedEnabled(',
    'private func requestedBinding(', 'private func requestedCatalogProjectID(',
    'private func migrateRequestedBinding(', 'private func requestedStateValue(',
    'private func migrateReferenceDisabledBinding(',
    'private func setProjectRequestedEnabled(', 'func isPatchEnabled(',
    'private func requestedEnabled(', 'func recordPatchOffFailure(', 'func recordRecoveryOffFailure(',
    'private func clearRestoredAssociations(', 'func isPatchApplied(',
    'func patchApplicationState(', 'private func safeSlug(', 'private func patchStorageSlug(',
]


def production_sources():
    source = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
    transaction = (ROOT / 'ThreeOneOSFive/helpers/PatchTransaction.swift').read_text(encoding='utf-8')
    code = 'import Foundation\n'
    code += source[source.index('struct PatchRecoveryItem:'):source.index('struct PatchCategory:')]
    code += transaction[transaction.index('struct PatchTransactionReceipt:'):transaction.index('enum PatchTransaction {')]
    code += extract_function(source, 'enum PatchRestoreError:') + '\n'
    models = (ROOT / 'ThreeOneOSFive/helpers/PatchProjectModels.swift').read_text(encoding='utf-8')
    code += models[:models.index('enum PatchProjectAccessPolicy {')]
    code += (ROOT / 'Tests/CatalogRecoveryFixtures.swift').read_text(encoding='utf-8')
    code += extract_function(models, 'enum PatchPackageLimits {') + '\n'
    code += 'enum PatchPathValidator {\n'
    for signature in ['static func canonicalBundleIdentifier(', 'static func canonicalRelativePath(']:
        code += extract_function(models, signature) + '\n'
    code += '}\n'
    code += '''
@MainActor final class FeaturePatchService {
var defaults:UserDefaults { Fixture.defaults }
var catalogApplications:CatalogPatchApplicationRegistry { CatalogPatchApplicationRegistry(defaults:defaults) }
var patchProjectsDir:URL { Fixture.root }
var applicationRevision:UInt64=0
var recoveryItems:[PatchRecoveryItem]=[]
var recoveryInventoryError:String?
var patchOperationInProgress=false
private var pendingPatchOperations=0
private var requestedStateOverrides:[String:Bool]=[:]
private var requestedProjectOverrides:[UUID:Bool]=[:]
private var requestedStateBindings:[String:String]=[:]
private var requestedProjectBindings:[UUID:String]=[:]
private var verifiedCatalogVariantsByPatchID:[Int:Set<String>]=[:]
private var verifiedCatalogAuthRevision:UInt64?
func adoptVerifiedCatalogForFixture(_ variants:[Int:Set<String>], revision:UInt64=1) {
    verifiedCatalogVariantsByPatchID=variants;verifiedCatalogAuthRevision=revision
}
func localPatchURL(_ patch:PatchItem)->URL { Fixture.root.appendingPathComponent("unused-legacy-download") }
func downloadPatch(_ patch:PatchItem,auth:AuthManager)async throws->URL {
  Fixture.downloads += 1
  let url=Fixture.root.appendingPathComponent("download-"+UUID().uuidString)
  try Data([1]).write(to:url)
  return url
}
'''
    for signature in METHODS:
        code += extract_function(source, signature) + '\n'
    return code + '}\n'


class CatalogRecovery(unittest.TestCase):
    def test_production_catalog_and_recovery(self):
        compiler = shutil.which('swiftc')
        distro = os.environ.get('ASTRA_SWIFT_WSL_DISTRIBUTION')
        if compiler:
            command, translate = [compiler], str
            execute = lambda binary: [str(binary)]
        elif os.name == 'nt' and distro:
            compiler = subprocess.check_output(['wsl', '-d', distro, '--', 'bash', '-lc', 'command -v swiftc'], text=True).strip()
            command = ['wsl', '-d', distro, '--', compiler]
            def translate(value):
                value = str(Path(value).resolve()).replace('\\', '/')
                return '/mnt/' + value[0].lower() + value[2:]
            execute = lambda binary: ['wsl', '-d', distro, '--', translate(binary)]
        else:
            self.skipTest('requires Swift; ASTRA_SWIFT_WSL_DISTRIBUTION enables Windows checks')
        code = production_sources()
        # Linux has no iOS File Protection option; no transaction logic changes.
        if os.name == 'nt' and distro:
            code = code.replace('.completeFileProtection', '.atomic')
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source, binary = folder / 'ActualCatalog.swift', folder / 'catalog-recovery'
            source.write_text(code, encoding='utf-8')
            subprocess.run(command + ['-swift-version', '5', translate(source),
                translate(ROOT / 'Tests/CatalogRecoverySelfCheck.swift'), '-o', translate(binary)], check=True)
            subprocess.run(execute(binary), check=True)


if __name__ == '__main__':
    unittest.main()
