"""Verify the actual iTech adapter with isolated native boundaries."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ScopedAdapter(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'requires macOS Foundation/ARC')
    def test_strategy_order_scope_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'scoped-adapter'
            subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                            str(ROOT / 'Tests/Viet99BQCoreSelfCheck.m'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_native_source_is_linked_and_transactions_reuse_grants(self):
        project = (ROOT / 'ThreeOneOSFive.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        self.assertIn('3105B001 /* Viet99BQCore.m in Sources */', project)
        header = (ROOT / 'ThreeOneOSFive/ThreeOneOSFive-Bridging-Header.h').read_text(encoding='utf-8')
        self.assertIn('#import "exploit/Viet99BQCore.h"', header)
        helper = (ROOT / 'ThreeOneOSFive/helpers/WorseQueryHelper.swift').read_text(encoding='utf-8')
        self.assertIn('ITechBQAcquireAccess(effectiveTarget, group)', helper)
        transaction = (ROOT / 'ThreeOneOSFive/helpers/PatchTransaction.swift').read_text(encoding='utf-8')
        self.assertIn('preparedAccess.requireRoot', transaction)
        self.assertIn('verifyRestoredRecords(resolved, baselines: restoreBaselines)', transaction)
