"""Execute the production observation/routing/merge policy and Postbox codec."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / 'tests'


class PeerProfileChangeTests(unittest.TestCase):
    def test_observation_routing_merging_and_persistence(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'Murmur.h').write_text('#include <stdint.h>\nint32_t murMurHashString32(const char *s);\n')
            (folder / 'module.modulemap').write_text('module MurMurHash32 { header "Murmur.h" export * }\n')
            source = (ROOT / 'submodules/MurMurHash32/Sources/MurMurHash32.m').read_text()
            source = source.replace('#import <MurMurHash32/MurMurHash32.h>', '#include "Murmur.h"')
            source = re.sub(r'int32_t murMurHash32Data\(NSData \*data\) \{.*?\n\}', '', source, flags=re.S)
            (folder / 'murmur.c').write_text(source)
            self.run_checked(['cc', '-c', str(folder / 'murmur.c'), '-o', str(folder / 'murmur.o')])
            postbox = ROOT / 'submodules/Postbox/Sources'
            coding = (postbox / 'Coding.swift').read_text()
            coding = coding.replace('NSMutableString()', 'NSMutableString(capacity: 0)')
            coding = coding.replace('hexString.appendFormat("%02x", UInt(bytes[i]))', 'hexString.append(String(format: "%02x", UInt(bytes[i])))')
            (folder / 'Coding.swift').write_text(coding)
            cache_entry = (postbox / 'PreferencesEntry.swift').read_text().split('public final class PreferencesEntry:', 1)[0]
            (folder / 'CacheEntry.swift').write_text(cache_entry.replace('public ', ''))
            policy = (ROOT / 'submodules/TelegramCore/Sources/SyncCore/SyncCore_ArielgramPeerProfileChanges.swift').read_text()
            (folder / 'Policy.swift').write_text(policy.replace('import Postbox\n', '').replace('public ', ''))
            (folder / 'main.swift').write_text((FIXTURES / 'peer_profile_change_policy.swift').read_text())
            sources = [folder / 'Coding.swift', folder / 'CacheEntry.swift', *postbox.glob('Utils/Encoder/*.swift'), *postbox.glob('Utils/Decoder/*.swift'), FIXTURES / 'peer_profile_change_models.swift', folder / 'Policy.swift', folder / 'main.swift']
            self.run_checked(['swiftc', '-I', str(folder), *map(str, sources), str(folder / 'murmur.o'), '-o', str(folder / 'tests')])
            self.run_checked([str(folder / 'tests')])

    def run_checked(self, command):
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
