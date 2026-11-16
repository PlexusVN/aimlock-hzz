"""Verify metadata survives the real encrypted .3105 codec on macOS."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function

ROOT = Path(__file__).resolve().parents[1]


class GenericPackageTargets(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'),
                         'requires macOS CryptoKit, CommonCrypto and Security')
    def test_actual_codec_preserves_and_rejects_non_application_targets(self):
        models = (ROOT / 'ThreeOneOSFive/helpers/PatchProjectModels.swift').read_text(encoding='utf-8')
        source = models[:models.index('extension PatchPackageError: LocalizedError')]
        source += extract_function(models, 'enum PatchPackageLimits {') + '\n'
        source += 'enum PatchPathValidator {\n'
        for signature in ['static func canonicalBundleIdentifier(', 'static func canonicalRelativePath(']:
            source += extract_function(models, signature) + '\n'
        source += '}\n'
        feature = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
        source += '''
enum ProtectedDownloadError: Error { case invalidResponse }
final class FeaturePatchService {
    func validate(_ project:PatchProject,variant:String) throws {
        try validateCatalogPackageTargets(project,variant:variant)
    }
'''
        source += extract_function(feature, 'private func validateCatalogPackageTargets(') + '\n}\n'
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            actual = folder / 'ActualGenericPackageTargets.swift'
            actual.write_text(source, encoding='utf-8')
            binary = folder / 'generic-package-targets'
            subprocess.run(['swiftc', '-swift-version', '5', str(actual),
                            str(ROOT / 'ThreeOneOSFive/helpers/AppSecurityConfiguration.swift'),
                            str(ROOT / 'ThreeOneOSFive/helpers/PatchPackageCodec.swift'),
                            str(ROOT / 'Tests/GenericPackageTargetSelfCheck.swift'),
                            '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
