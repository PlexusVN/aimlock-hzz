"""Compile the production progress/lifecycle wrapper against controllable workers."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function

ROOT = Path(__file__).resolve().parents[1]


class CatalogProgressChecks(unittest.TestCase):
    def test_retained_task_progress_and_precommit_cancellation(self):
        compiler = shutil.which('swiftc')
        distro = os.environ.get('ASTRA_SWIFT_WSL_DISTRIBUTION')
        if compiler:
            command, translate = [compiler], str
            execute = lambda filename: [str(filename)]
        elif os.name == 'nt' and distro:
            compiler = subprocess.check_output(['wsl', '-d', distro, '--', 'bash', '-lc', 'command -v swiftc'], text=True).strip()
            command = ['wsl', '-d', distro, '--', compiler]

            def translate(filename):
                value = str(Path(filename).resolve()).replace('\\', '/')
                return '/mnt/' + value[0].lower() + value[2:]
            execute = lambda filename: ['wsl', '-d', distro, '--', translate(filename)]
        else:
            self.skipTest('requires Swift; ASTRA_SWIFT_WSL_DISTRIBUTION enables Windows checks')

        source = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
        fixture = (ROOT / 'Tests/CatalogProgressSelfCheck.swift').read_text(encoding='utf-8')
        fixture = fixture.replace('// ACTUAL_PROGRESS', source[source.index('struct FeaturePatchOperationProgress:'):source.index('// END CATALOG OPERATION PROGRESS')])
        methods = [
            'func cancelPatchOperation(identity:', 'private func cancelPatchOperation(operationID:',
            'private func markPatchCancellationPending(', 'private func updatePatchOperation(',
            'private func beginPatchCommit(', 'static func isPatchOperationCancellation(',
            'private func withCatalogOperation<', 'private func beginPatchOperation(',
            'private func endPatchOperation(',
        ]
        fixture = fixture.replace('// ACTUAL_METHODS', '\n'.join(extract_function(source, signature) for signature in methods))
        transaction = (ROOT / 'ThreeOneOSFive/helpers/PatchTransaction.swift').read_text(encoding='utf-8')
        fixture = fixture.replace('// ACTUAL_GATE', transaction[transaction.index('actor PatchFilesystemGate {'):transaction.index('// END PATCH FILESYSTEM GATE')])
        with tempfile.TemporaryDirectory() as directory:
            actual = Path(directory) / 'ActualCatalogProgress.swift'
            binary = Path(directory) / 'catalog-progress'
            actual.write_text(fixture, encoding='utf-8')
            subprocess.run(command + ['-swift-version', '5', '-parse-as-library', translate(actual), '-o', translate(binary)], check=True)
            subprocess.run(execute(binary), check=True)


if __name__ == '__main__':
    unittest.main()
