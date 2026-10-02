"""Exercise production send gates with delayed forward confirmations and draft release."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_client_features import body

ROOT = Path(__file__).resolve().parents[2]


class ForwardSendOrderTests(unittest.TestCase):
    def test_confirmation_order_and_draft_release(self):
        source = (ROOT / 'submodules/TelegramCore/Sources/State/PendingMessageManager.swift').read_text()
        declarations = '\n'.join(body(source, marker) for marker in [
            'public struct PendingMessageStatus:', 'private enum PendingMessageState',
            'private final class PendingMessageContext', 'public enum PendingMessageFailureReason',
            'private enum PendingMessageResult',
        ]).replace('private ', '').replace('public ', '')
        methods = '\n'.join(body(source, 'private func ' + marker) for marker in [
            'shouldGateSend(', 'isSendGateOpen(', 'isMessageSendGateClosed(',
            'drainWaitingSendGates(', 'drainSendGate(', 'beginSendingMessage(',
            'dataForPendingMessageGroup(', 'commitSendingMessageGroup(',
            'commitSendingSingleMessage(',
        ]).replace('private ', '')
        signals = ROOT / 'submodules/SSignalKit/SwiftSignalKit/Source'
        support = '\n'.join((signals / name).read_text() for name in [
            'Atomic.swift', 'Disposable.swift', 'Subscriber.swift', 'Bag.swift',
        ])
        support += (signals / 'Signal.swift').read_text().split('@available', 1)[0]
        support += body((signals / 'Signal_Mapping.swift').read_text(), 'public func map<')
        fixture = (Path(__file__).parent / 'tests/forward_send_order.swift').read_text()
        code = '\n'.join([support, declarations, fixture.replace('// Production gate methods.', methods)])
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / 'main.swift'
            main.write_text(code)
            for command in [['swiftc', str(main), '-o', str(folder / 'tests')], [str(folder / 'tests')]]:
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
