import threading
import unittest
from unittest.mock import patch

from test_lifecycle import load_module

capture = load_module('rtp_capture', 'capture.py')


class CaptureTests(unittest.TestCase):
    def test_duration_starts_after_readiness_and_operator_marker(self):
        now = [0]
        timing = capture.CaptureTiming(180, lambda: now[0])
        with self.assertRaises(ValueError):
            timing.mark()
        timing.video_ready = True
        self.assertFalse(timing.ready())
        timing.audio_ready = True
        now[0] = 120
        self.assertTrue(timing.ready())
        self.assertFalse(timing.expired())
        now[0] = 150
        timing.mark()
        now[0] = 329
        self.assertFalse(timing.expired())
        now[0] = 330
        self.assertTrue(timing.expired())

    def test_stalled_shutdown_has_a_deadline(self):
        release = threading.Event()
        try:
            with self.assertRaises(TimeoutError):
                capture.bounded_call(release.wait, timeout=0.02)
        finally:
            release.set()

    def test_shutdown_failure_is_reported(self):
        def fail():
            raise RuntimeError('failed')
        with self.assertRaisesRegex(RuntimeError, 'failed'):
            capture.bounded_call(fail)

    def test_restores_owned_microphone_gain(self):
        sources = [{'name': 'microphone', 'volume': {'left': {'value': 16384}}}]
        with patch.object(capture, 'pulse_sources', return_value=sources), patch.object(capture.subprocess, 'run') as command:
            self.assertTrue(capture.restore_microphone('microphone', 25, ['65536']))
            command.assert_called_once_with(['pactl', 'set-source-volume', 'microphone', '65536'], check=True, timeout=5)

    def test_preserves_manual_microphone_change(self):
        sources = [{'name': 'microphone', 'volume': {'left': {'value': 20000}}}]
        with patch.object(capture, 'pulse_sources', return_value=sources), patch.object(capture.subprocess, 'run') as command:
            self.assertFalse(capture.restore_microphone('microphone', 25, ['65536']))
            command.assert_not_called()
