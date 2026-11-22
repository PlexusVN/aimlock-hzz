"""Run production image cache/download methods with isolated transport and image decoding."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function

ROOT = Path(__file__).resolve().parents[1]


class FeatureImageChecks(unittest.TestCase):
    def test_cards_use_feature_images_and_sync_refreshes_them(self):
        ui = (ROOT / 'ThreeOneOSFive/views/FeaturesView.swift').read_text(encoding='utf-8')
        card = extract_function(ui, 'private var patchImage:')
        self.assertIn('service.cachedImage(for: patch)', card)
        self.assertNotIn('categoryImage(', card)
        self.assertNotIn('AimlockReticleIcon()', card)
        source = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
        sync = extract_function(source, 'func syncFromServer(')
        self.assertIn('downloadPatchImageIfNeeded(patch, force: true)', sync)

    def test_server_images_cache_replacement_and_late_responses(self):
        compiler = shutil.which('swiftc')
        distro = os.environ.get('ASTRA_SWIFT_WSL_DISTRIBUTION')
        if compiler:
            command, translate = [compiler], str
            execute = lambda path: [str(path)]
        elif os.name == 'nt' and distro:
            compiler = subprocess.check_output(
                ['wsl', '-d', distro, '--', 'bash', '-lc', 'command -v swiftc'], text=True).strip()
            command = ['wsl', '-d', distro, '--', compiler]

            def translate(path):
                value = str(Path(path).resolve()).replace('\\', '/')
                return '/mnt/' + value[0].lower() + value[2:]

            execute = lambda path: ['wsl', '-d', distro, '--', translate(path)]
        else:
            self.skipTest('requires Swift; ASTRA_SWIFT_WSL_DISTRIBUTION enables Windows checks')
        source = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
        methods = '\n'.join(extract_function(source, signature) for signature in [
            'private func localImageURL(', 'private func fullImageURL(',
            'private func localCategoryImageURL(', 'func categoryImage(',
            'func downloadCategoryImageIfNeeded(', 'func downloadPatchImageIfNeeded(',
            'func cachedImage(',
        ])
        fixture = (ROOT / 'Tests/FeatureImagesSelfCheck.swift').read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory() as directory:
            actual, binary = Path(directory) / 'Images.swift', Path(directory) / 'images-check'
            actual.write_text(fixture.replace('// PRODUCTION_METHODS', methods), encoding='utf-8')
            subprocess.run(command + ['-swift-version', '5', '-parse-as-library', translate(actual),
                                     '-o', translate(binary)], check=True)
            subprocess.run(execute(binary), check=True)


if __name__ == '__main__':
    unittest.main()
