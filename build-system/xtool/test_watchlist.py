"""Execute watchlist policy, real Postbox persistence, and history anchors."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from test_client_features import body

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / 'tests'


class WatchlistTests(unittest.TestCase):
    def run_checked(self, command):
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_membership_storage_and_reading_positions(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'Murmur.h').write_text('#include <stdint.h>\nint32_t murMurHashString32(const char *s);\n')
            (folder / 'module.modulemap').write_text('module MurMurHash32 { header "Murmur.h" export * }\n')
            murmur = (ROOT / 'submodules/MurMurHash32/Sources/MurMurHash32.m').read_text()
            murmur = murmur.replace('#import <MurMurHash32/MurMurHash32.h>', '#include "Murmur.h"')
            murmur = re.sub(r'int32_t murMurHash32Data\(NSData \*data\) \{.*?\n\}', '', murmur, flags=re.S)
            (folder / 'murmur.c').write_text(murmur)
            self.run_checked(['cc', '-c', str(folder / 'murmur.c'), '-o', str(folder / 'murmur.o')])
            postbox = ROOT / 'submodules/Postbox/Sources'
            coding = (postbox / 'Coding.swift').read_text()
            coding = coding.replace('NSMutableString()', 'NSMutableString(capacity: 0)')
            coding = coding.replace('hexString.appendFormat("%02x", UInt(bytes[i]))', 'hexString.append(String(format: "%02x", UInt(bytes[i])))')
            (folder / 'Coding.swift').write_text(coding)
            core = ROOT / 'submodules/TelegramCore/Sources'
            ui = ROOT / 'submodules/TelegramUI/Sources'
            policy = (core / 'Settings/ArielgramWatchlist.swift').read_text()
            policy = re.sub(r'^import (?!Foundation).+\n', '', policy, flags=re.M)
            declarations = '\n'.join([
                body((postbox / 'Peer.swift').read_text(), 'public struct PeerId:'),
                body((postbox / 'PreferencesEntry.swift').read_text(), 'public final class PreferencesEntry:'),
                (core / 'TelegramEngine/Utils/StringCodingKey.swift').read_text(),
                policy,
                body((ui / 'ChatHistoryViewForLocation.swift').read_text(), 'private func watchlistHistoryAnchor('),
            ])
            (folder / 'Policy.swift').write_text(declarations.replace('public ', '').replace('private func watchlistHistoryAnchor', 'func watchlistHistoryAnchor'))
            fixture = (FIXTURES / 'watchlist_models.swift').read_text()
            scroll = body((ui / 'ChatHistoryListNode.swift').read_text(), 'func immediateScrollState(')
            (folder / 'Models.swift').write_text(fixture.replace('// Production scroll-state function goes here.', scroll))
            (folder / 'main.swift').write_text((FIXTURES / 'watchlist_policy.swift').read_text())
            sources = [folder / 'Coding.swift', *postbox.glob('Utils/Encoder/*.swift'), *postbox.glob('Utils/Decoder/*.swift'), folder / 'Models.swift', folder / 'Policy.swift', folder / 'main.swift']
            self.run_checked(['swiftc', '-I', str(folder), *map(str, sources), str(folder / 'murmur.o'), '-o', str(folder / 'tests')])
            self.run_checked([str(folder / 'tests')])


if __name__ == '__main__':
    unittest.main()
