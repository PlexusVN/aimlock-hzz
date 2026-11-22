"""Best-effort, time-bounded cleanup of the one simulator created by the check."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time


def bounded_run(command, timeout):
    started = time.monotonic()
    try:
        result = subprocess.run(command, timeout=timeout, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, check=False)
        status = 'ok' if result.returncode == 0 else 'failed'
    except subprocess.TimeoutExpired:
        status = 'timeout'
    except OSError:
        status = 'unavailable'
    return {'status': status, 'seconds': round(time.monotonic() - started, 3)}


def cleanup(device, run=bounded_run):
    if not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', device):
        raise ValueError('invalid isolated simulator ID')
    return {action: run(['xcrun', 'simctl', action, device], timeout)
            for action, timeout in [('shutdown', 30), ('delete', 20)]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('device')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = cleanup(args.device)
    args.report.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('[native-video-check] Cleanup: ' + json.dumps(report))
