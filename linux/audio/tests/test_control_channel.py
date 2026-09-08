import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pairing import Channel


class ControlChannelTests(unittest.TestCase):
    def channel(self, response):
        process = Mock(stdin=io.StringIO(), stdout=io.StringIO(json.dumps(response) + '\n'))
        with patch('pairing.subprocess.Popen', return_value=process):
            return Channel(Mock(), {})

    def test_recovery_status_keeps_original_error_and_generation(self):
        response = {'state': 'recoveryPending', 'generation': 2, 'error': 'Audio process exited'}
        channel = self.channel(response)
        with patch('pairing.select.select', return_value=([channel.process.stdout], [], [])):
            self.assertEqual(channel.request({'action': 'heartbeat'}), response)

    def test_command_error_still_fails(self):
        channel = self.channel({'error': 'No receiver session is active'})
        with patch('pairing.select.select', return_value=([channel.process.stdout], [], [])):
            with self.assertRaisesRegex(RuntimeError, 'No receiver session'):
                channel.request({'action': 'heartbeat'})
