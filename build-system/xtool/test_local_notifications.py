"""Exercise production background eligibility, deduplication and spoiler privacy."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_client_features import body

ROOT = Path(__file__).resolve().parents[2]


class LocalNotificationTests(unittest.TestCase):
    def test_background_delivery_and_privacy(self):
        source = (ROOT / 'submodules/TelegramUI/Sources/SharedNotificationManager.swift').read_text()
        declarations = '\n'.join(body(source, marker) for marker in [
            'private struct ArielgramLocalNotificationGate',
            'private func arielgramNotificationIdentifier(',
            'private func arielgramNotificationPreview(',
        ]).replace('private ', '')
        fixture = (Path(__file__).parent / 'tests/local_notifications.swift').read_text()
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / 'main.swift'
            main.write_text('import Foundation\n' + declarations + '\n' + fixture)
            for command in [['swiftc', str(main), '-o', str(folder / 'tests')], [str(folder / 'tests')]]:
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
