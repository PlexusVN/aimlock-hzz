"""Run the production transaction engine against real temporary files and faults."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function

ROOT = Path(__file__).resolve().parents[1]


def production_sources():
    models = (ROOT / 'ThreeOneOSFive/helpers/PatchProjectModels.swift').read_text(encoding='utf-8')
    start = models.index('extension PatchPackageError: LocalizedError')
    end = models.index('enum PatchOperationStage:')
    # Only UI localization is replaced. Filesystem validation/models stay exact.
    models = models[:start] + models[end:]
    models = models[:models.index('enum PatchOperationStage:')] + models[models.index('enum PatchPackageLimits {'):]
    models += '\nextension PatchPackageError: LocalizedError { var errorDescription: String? { String(describing: self) } }\n'
    transaction = (ROOT / 'ThreeOneOSFive/helpers/PatchTransaction.swift').read_text(encoding='utf-8')
    transaction = transaction[:transaction.index('// MARK: - Device Patch Service')]
    executor = (ROOT / 'ThreeOneOSFive/helpers/DirectPatchExecutor.swift').read_text(encoding='utf-8')
    feature = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
    presentation = extract_function(feature, 'struct PatchRecoveryItem:') + '\n'
    presentation += extract_function(feature, 'private struct CatalogRecoveryMetadata:') + '\n'
    presentation += feature.split('// BEGIN CATALOG PRESENTATION SNAPSHOT', 1)[1].split('// END CATALOG PRESENTATION SNAPSHOT', 1)[0]
    return models + '\n' + transaction + '\n' + executor + '\n' + presentation


class DirectFilesystemRecovery(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'),
                         'requires macOS CryptoKit and Darwin file APIs')
    def test_reference_provenance_and_final_restore_verification(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source = folder / 'ActualTransaction.swift'
            # Target roots are owned temporary directories supplied explicitly
            # by the fixture; device container discovery never runs here.
            boundary = '\nenum ContainerStore { static func isApplicationContainerPath(_ path: String) -> Bool { false } }\n'
            source.write_text(production_sources() + boundary, encoding='utf-8')
            binary = folder / 'reference-provenance-restore'
            subprocess.run(['swiftc', '-swift-version', '5', str(source),
                            str(ROOT / 'Tests/DirectTransactionProvenanceSelfCheck.swift'),
                            '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'),
                         'requires macOS CryptoKit and Darwin file APIs')
    def test_actual_temporary_files_and_recovery(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source = folder / 'ActualTransaction.swift'
            source.write_text(production_sources(), encoding='utf-8')
            binary = folder / 'direct-filesystem-recovery'
            subprocess.run(['swiftc', '-swift-version', '5', str(source),
                            str(ROOT / 'Tests/DirectFilesystemRecoverySelfCheck.swift'),
                            '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
