"""Run production display policy and background-audio lifecycle on host fixtures."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / 'tests'


def body(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    index = opening + 1
    while depth:
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
    return source[start:index]


class ClientFeatureTests(unittest.TestCase):
    def run_checked(self, command):
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_display_policy_and_background_audio_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            core = ROOT / 'submodules/TelegramCore/Sources'
            settings = (ROOT / 'Swiftgram/SGSimpleSettings/Sources/SimpleSettings.swift').read_text()
            defaults = (ROOT / 'Swiftgram/SGSimpleSettings/Sources/UserDefaultsWrapper.swift').read_text().split('//public class AtomicUserDefault', 1)[0]
            setting = body(settings, '@UserDefault(key: Keys.arielgramBackgroundMonitoring.rawValue)')
            setting = setting.replace('Keys.arielgramBackgroundMonitoring.rawValue)', 'Keys.arielgramBackgroundMonitoring.rawValue, userDefaults: testDefaults)')
            properties = '\n'.join(body(settings, marker) for marker in ['public var status: Int64', 'public var ephemeralStatus: Int64'])
            background = (ROOT / 'submodules/TelegramUI/Sources/ArielgramBackgroundMonitoring.swift').read_text()
            background = re.sub(r'^import (?!Foundation).+\n', '', background, flags=re.M)
            # File protection is Darwin-only; the lifecycle tests inject the
            # player factory and exercise the unmodified controller behavior.
            background = background.replace('.completeFileProtectionUntilFirstUserAuthentication', 'Data.WritingOptions(rawValue: 0)')
            content = body((core / 'Settings/ContentSettings.swift').read_text(), 'public struct ContentSettings:')
            peer = body((core / 'Utils/PeerUtils.swift').read_text(), 'func restrictionText(')
            restrictions = (ROOT / 'submodules/PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift').read_text()
            restrictions = re.sub(r'^import (?!Foundation).+\n', '', restrictions, flags=re.M)
            status = body((ROOT / 'Swiftgram/SGStatus/Sources/SGStatus.swift').read_text(), 'public struct SGStatus:')
            code = '\n'.join([
                defaults,
                (FIXTURES / 'client_feature_models.swift').read_text().replace('// Production settings go here.', setting + '\n' + properties),
                content, 'extension Peer {\n' + peer + '\n}', restrictions,
                status, background,
            ]).replace('public ', '')
            (folder / 'Production.swift').write_text(code)
            (folder / 'main.swift').write_text((FIXTURES / 'client_feature_policy.swift').read_text())
            self.run_checked(['swiftc', str(folder / 'Production.swift'), str(folder / 'main.swift'), '-o', str(folder / 'tests')])
            self.run_checked([str(folder / 'tests'), str(folder / 'silence.wav')])
            with wave.open(str(folder / 'silence.wav')) as audio:
                self.assertEqual((audio.getnchannels(), audio.getsampwidth(), audio.getframerate()), (1, 2, 8000))
                self.assertEqual(audio.getnframes() / audio.getframerate(), 600)
                self.assertFalse(any(audio.readframes(audio.getnframes())))

    def test_paused_media_handoff_preserves_background_and_calls(self):
        source = (ROOT / 'submodules/TelegramAudio/Sources/ManagedAudioSession.swift').read_text()
        drop = body(source, 'public func dropAll()').replace('public ', '')
        fixture = (FIXTURES / 'client_feature_handoff.swift').read_text()
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / 'main.swift'
            main.write_text(fixture.replace('// Production dropAll goes here.', drop))
            self.run_checked(['swiftc', str(main), '-o', str(folder / 'tests')])
            self.run_checked([str(folder / 'tests')])


if __name__ == '__main__':
    unittest.main()
