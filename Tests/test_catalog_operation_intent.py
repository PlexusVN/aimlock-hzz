"""Execute the real public catalog entries and filesystem gate under session changes."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function

ROOT = Path(__file__).resolve().parents[1]


class CatalogOperationIntentChecks(unittest.TestCase):
    def test_queued_apply_restore_belong_to_requesting_auth_session(self):
        compiler = shutil.which('swiftc')
        distro = os.environ.get('ASTRA_SWIFT_WSL_DISTRIBUTION')
        if compiler:
            command, translate = [compiler], str
            execute = lambda binary: [str(binary)]
        elif os.name == 'nt' and distro:
            compiler = subprocess.check_output(
                ['wsl', '-d', distro, '--', 'bash', '-lc', 'command -v swiftc'], text=True).strip()
            command = ['wsl', '-d', distro, '--', compiler]
            def translate(value):
                value = str(Path(value).resolve()).replace('\\', '/')
                return '/mnt/' + value[0].lower() + value[2:]
            execute = lambda binary: ['wsl', '-d', distro, '--', translate(binary)]
        else:
            self.skipTest('requires Swift; ASTRA_SWIFT_WSL_DISTRIBUTION enables Windows checks')
        source = (ROOT / 'Tests/CatalogOperationIntentSelfCheck.swift').read_text(encoding='utf-8')
        transaction = (ROOT / 'ThreeOneOSFive/helpers/PatchTransaction.swift').read_text(encoding='utf-8')
        gate = transaction[transaction.index('actor PatchFilesystemGate {'):transaction.index('// END PATCH FILESYSTEM GATE')]
        feature = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
        source = source.replace('// ACTUAL_PROGRESS', feature[feature.index('struct FeaturePatchOperationProgress:'):feature.index('// END CATALOG OPERATION PROGRESS')])
        helpers = ['func cancelPatchOperation(identity:', 'private func cancelPatchOperation(operationID:',
                   'private func markPatchCancellationPending(', 'private func updatePatchOperation(',
                   'private func beginPatchCommit(', 'static func isPatchOperationCancellation(',
                   'private func withCatalogOperation<']
        source = source.replace('// ACTUAL_LIFECYCLE', '\n'.join(extract_function(feature, name) for name in helpers))
        source = source.replace('// ACTUAL_GATE', gate)
        source = source.replace('// ACTUAL_APPLY_ENTRY', extract_function(feature, 'func applyPatch('))
        source = source.replace('// ACTUAL_RESTORE_ENTRY', extract_function(feature, 'func restorePatch('))
        source = source.replace('// ACTUAL_SESSION_GATE', extract_function(feature, 'private func withAuthenticatedPatchOperation<'))
        with tempfile.TemporaryDirectory() as directory:
            actual = Path(directory) / 'ActualCatalogOperationIntent.swift'
            actual.write_text(source, encoding='utf-8')
            binary = Path(directory) / 'catalog-operation-intent'
            subprocess.run(command + ['-swift-version', '5', '-parse-as-library', translate(actual),
                                     '-o', translate(binary)], check=True)
            subprocess.run(execute(binary), check=True)


if __name__ == '__main__':
    unittest.main()
