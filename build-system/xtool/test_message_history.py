"""Execute history policy + the real Postbox codec on the Linux build host.

The small model fixtures replace platform message/transaction interfaces, not
the history implementation or serialization. Device tests cover UI/database use.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / 'tests'


class MessageHistoryPolicyTests(unittest.TestCase):
    def test_versions_deletions_storage_and_codec(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'Murmur.h').write_text('#include <stdint.h>\nint32_t murMurHashString32(const char *s);\n')
            (folder / 'module.modulemap').write_text('module MurMurHash32 { header "Murmur.h" export * }\n')
            source = (ROOT / 'submodules/MurMurHash32/Sources/MurMurHash32.m').read_text()
            source = source.replace('#import <MurMurHash32/MurMurHash32.h>', '#include "Murmur.h"')
            # NSData's wrapper is not needed for the codec's type hashes.
            source = re.sub(r'int32_t murMurHash32Data\(NSData \*data\) \{.*?\n\}', '', source, flags=re.S)
            (folder / 'murmur.c').write_text(source)
            self.run_checked(['cc', '-c', str(folder / 'murmur.c'), '-o', str(folder / 'murmur.o')])

            postbox = ROOT / 'submodules/Postbox/Sources'
            coding = (postbox / 'Coding.swift').read_text()
            # swift-corelibs Foundation lacks two NSString conveniences. These
            # substitutions only affect MemoryBuffer.description, not encoding.
            coding = coding.replace('NSMutableString()', 'NSMutableString(capacity: 0)')
            coding = coding.replace('hexString.appendFormat("%02x", UInt(bytes[i]))', 'hexString.append(String(format: "%02x", UInt(bytes[i])))')
            (folder / 'Coding.swift').write_text(coding)
            sources = [folder / 'Coding.swift', *postbox.glob('Utils/Encoder/*.swift'), *postbox.glob('Utils/Decoder/*.swift'), FIXTURES / 'message_history_models.swift']
            self.run_checked(['swiftc', '-emit-module', '-emit-library', '-module-name', 'Postbox', '-I', str(folder), *map(str, sources), str(folder / 'murmur.o'), '-o', str(folder / 'libPostbox.so')])
            (folder / 'main.swift').write_text((FIXTURES / 'message_history_policy.swift').read_text())
            self.run_checked(['swiftc', '-I', str(folder), '-L', str(folder), '-lPostbox', str(ROOT / 'submodules/TelegramCore/Sources/SyncCore/SyncCore_ArielgramMessageHistory.swift'), str(FIXTURES / 'message_history_core_models.swift'), str(folder / 'main.swift'), '-o', str(folder / 'tests')])
            self.run_checked([str(folder / 'tests')], env=dict(os.environ, LD_LIBRARY_PATH=str(folder)))

    def run_checked(self, command, **kwargs):
        result = subprocess.run(command, capture_output=True, text=True, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
