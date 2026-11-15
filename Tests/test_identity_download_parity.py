"""Exercise production identity preparation and explicit download failure flow."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function

ROOT = Path(__file__).resolve().parents[1]


class IdentityDownloadParity(unittest.TestCase):
    def test_production_preparation_and_download_failure(self):
        source = (ROOT / 'ThreeOneOSFive/helpers/ProtectedDownloadService.swift').read_text(encoding='utf-8')
        fixture = (ROOT / 'Tests/IdentityDownloadParitySelfCheck.swift').read_text(encoding='utf-8')
        fixture = fixture.replace('// ACTUAL_PREPARE_IDENTITY', extract_function(source, 'private func prepareIdentity('))
        fixture = fixture.replace('// ACTUAL_LOCAL_IDENTITY_FAILURE', extract_function(source, 'private func recordLocalDownloadIdentityFailure('))
        fixture = fixture.replace('// ACTUAL_DOWNLOAD', extract_function(source, 'func download('))
        compiler = shutil.which('swiftc')
        distro = os.environ.get('ASTRA_SWIFT_WSL_DISTRIBUTION')
        if compiler:
            command, translate = [compiler], str
            execute = lambda path: [str(path)]
        elif os.name == 'nt' and distro:
            compiler = subprocess.check_output(['wsl', '-d', distro, '--', 'bash', '-lc', 'command -v swiftc'], text=True).strip()
            command = ['wsl', '-d', distro, '--', compiler]
            def translate(path):
                value = str(Path(path).resolve()).replace('\\', '/')
                return '/mnt/' + value[0].lower() + value[2:]
            execute = lambda path: ['wsl', '-d', distro, '--', translate(path)]
        else:
            self.skipTest('requires Swift; ASTRA_SWIFT_WSL_DISTRIBUTION enables Windows checks')
        with tempfile.TemporaryDirectory() as folder:
            actual = Path(folder) / 'ActualIdentityDownload.swift'
            actual.write_text(fixture, encoding='utf-8')
            binary = Path(folder) / 'identity-download-check'
            subprocess.run(command + ['-swift-version', '5', '-parse-as-library', translate(actual), '-o', translate(binary)], check=True)
            subprocess.run(execute(binary), check=True)


if __name__ == '__main__':
    unittest.main()
