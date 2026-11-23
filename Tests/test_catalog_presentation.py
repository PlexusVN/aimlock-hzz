"""Run display snapshots, coalescing and stale-result rejection with isolated disk state."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from check_airlift_pairing_finish import extract_function
from test_patch_operation_boundaries import swift_tools

ROOT = Path(__file__).resolve().parents[1]


class CatalogPresentationTests(unittest.TestCase):
    def test_snapshot_intent_deduplication_and_async_publication(self):
        feature = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
        region = feature.split('// BEGIN CATALOG PRESENTATION SNAPSHOT', 1)[1].split('// END CATALOG PRESENTATION SNAPSHOT', 1)[0]
        types = extract_function(feature, 'struct PatchRecoveryItem:') + '\n' + extract_function(feature, 'private struct CatalogRecoveryMetadata:')
        methods = '\n'.join(extract_function(feature, name) for name in [
            'func presentation(for patch:', 'private func updateDisplayedIntent(', 'private func requestPresentationRefresh(',
            'private func suspendPresentationRefresh(', 'private func safeSlug(',
        ])
        fixture = (ROOT / 'Tests/CatalogPresentationSelfCheck.swift').read_text(encoding='utf-8')
        code = fixture.replace('// PRESENTATION_TYPES', types + region).replace('// PRESENTATION_METHODS', methods)
        compiler, translate, execute = swift_tools()
        with tempfile.TemporaryDirectory() as directory:
            actual, binary = Path(directory) / 'ActualPresentation.swift', Path(directory) / 'presentation'
            actual.write_text(code, encoding='utf-8')
            subprocess.run(compiler + ['-swift-version', '5', '-parse-as-library', translate(actual), '-o', translate(binary)], check=True)
            subprocess.run(execute(binary), check=True)

    def test_render_and_tab_paths_do_not_reopen_storage(self):
        feature = (ROOT / 'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text(encoding='utf-8')
        ui = (ROOT / 'ThreeOneOSFive/views/FeaturesView.swift').read_text(encoding='utf-8')
        for name in ['func presentation(for patch:', 'func displayPatchImage(', 'func displayCategoryImage(']:
            body = extract_function(feature, name)
            for forbidden in ['FileManager', 'Data(contentsOf:', 'defaults.', 'patchApplicationState(', 'isPatchEnabled(']:
                self.assertNotIn(forbidden, body)
        card = ui[ui.index('struct PatchCardView:'):]
        self.assertNotIn('service.patchApplicationState(', card)
        self.assertNotIn('service.isPatchEnabled(', card)
        self.assertNotIn('service.cachedImage(', card)
        self.assertNotIn('AsyncImage(', extract_function(ui, 'private func categoryArtwork('))
        content = (ROOT / 'ThreeOneOSFive/ContentView.swift').read_text(encoding='utf-8')
        self.assertIn('mountedSections.contains', extract_function(content, 'private var mountedTabContents:'))
        self.assertIn('mountedSections.insert', extract_function(content, 'private func selectTab('))
        self.assertNotIn('.id(selectedVisibleSection.rawValue)', content)
        self.assertNotIn('.animation(AppTheme.gamingContentFade', content)


if __name__ == '__main__':
    unittest.main()
