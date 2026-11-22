from pathlib import Path
import importlib.util
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('simulator_cleanup', ROOT / 'ReleaseTools/simulator_cleanup.py')
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)
DEVICE = '12345678-1234-1234-1234-123456789abc'


class SimulatorCleanupChecks(unittest.TestCase):
    def test_hanging_process_is_killed_within_its_deadline(self):
        started = time.monotonic()
        result = cleanup.bounded_run([sys.executable, '-c', 'import time; time.sleep(30)'], .1)
        self.assertEqual(result['status'], 'timeout')
        self.assertLess(time.monotonic() - started, 3)

    def test_delete_is_attempted_after_shutdown_timeout(self):
        calls = []
        def run(command, timeout):
            calls.append((command, timeout))
            return {'status': 'timeout' if command[2] == 'shutdown' else 'ok'}
        report = cleanup.cleanup(DEVICE, run)
        self.assertEqual(report['shutdown']['status'], 'timeout')
        self.assertEqual(report['delete']['status'], 'ok')
        self.assertEqual(calls, [(['xcrun', 'simctl', 'shutdown', DEVICE], 30),
                                 (['xcrun', 'simctl', 'delete', DEVICE], 20)])

    def test_cleanup_never_targets_all_or_an_unvalidated_device(self):
        for invalid in ['all', '', DEVICE + ';anything', 'booted']:
            with self.assertRaises(ValueError):
                cleanup.cleanup(invalid, lambda *_: self.fail('invalid device dispatched'))

    def test_real_process_failure_is_reported(self):
        result = cleanup.bounded_run([sys.executable, '-c', 'raise SystemExit(2)'], 3)
        self.assertEqual(result['status'], 'failed')

    def test_exit_trap_preserves_the_check_result(self):
        script = (ROOT / 'ReleaseTools/run_video_background_simulator_check.sh').read_text(encoding='utf-8')
        self.assertIn('local result=$?', script)
        self.assertIn('return "$result"', script)
        self.assertIn('simulator_cleanup.py', script)
        self.assertNotIn('xcrun simctl shutdown "$DEVICE_ID"', script)


if __name__ == '__main__':
    unittest.main()
