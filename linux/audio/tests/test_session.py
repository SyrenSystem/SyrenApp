import threading
import time
import unittest
from unittest.mock import Mock

from test_ingress import PacketFilter, packet
from session import Session


class FakeGraph:
    def __init__(self):
        self.muted = None
        self.volume = 10
        self.latency = 20
        self.period = 128
        self.terminated = False
        self.fail_mute = False

    def start(self):
        self.muted = True

    def stop(self):
        self.terminated = True
        return True

    def set_volume(self, percent, muted):
        if self.fail_mute:
            raise TimeoutError('blocked control')
        self.volume, self.muted = percent, muted


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.ingress = Mock()
        self.ingress.filter = PacketFilter('127.0.0.1', 60, lambda: self.now)
        self.ingress.discarded = 0
        self.graphs = []
        def factory(port):
            graph = FakeGraph()
            self.graphs.append(graph)
            return graph
        self.session = Session('abc', self.ingress, factory, Mock(), clock=lambda: self.now)

    def advance(self, seconds=1.1, heartbeat=True):
        count = round(seconds / 0.0025)
        previous = self.ingress.filter.sequence or 0
        for index in range(count):
            self.now += 0.0025
            self.ingress.filter.accept(packet(previous + index + 1), ('127.0.0.1', 50000))
            if heartbeat:
                self.session.last_heartbeat = self.now
        self.session.tick()

    def ready(self):
        self.session.start()
        self.advance()
        self.assertEqual(self.session.state, 'readyMuted')

    def request(self, action, **values):
        return dict(version=1, session='abc', generation=self.session.generation, action=action, **values)

    def test_standby_keeps_graph_and_ingress_running(self):
        self.ready()
        graph = self.graphs[0]
        graph.standby = Mock()
        graph.selected_source = 'snapcast'
        self.session.request(self.request('unmute'))
        stale = self.request('unmute')
        self.session.request(self.request('standby'))
        self.assertEqual(self.session.state, 'readyMuted')
        self.assertTrue(self.session.muted)
        self.assertFalse(graph.terminated)
        self.assertEqual(len(self.graphs), 1)
        graph.standby.assert_called_once_with(False)
        with self.assertRaisesRegex(ValueError, 'Stale'):
            self.session.request(stale)
        self.session.request(self.request('unmute'))
        self.assertEqual(self.session.state, 'playing')
        self.assertEqual(len(self.graphs), 1)

    def test_standby_preserves_group_mute(self):
        self.ready()
        self.graphs[0].standby = Mock()
        self.session.request(self.request('standby', muted=True))
        self.graphs[0].standby.assert_called_once_with(True)

    def test_priority_mute_mutes_both_shared_branches(self):
        self.ready()
        self.graphs[0].mute_all = Mock()
        self.session.mute()
        self.graphs[0].mute_all.assert_called_once_with(10)

    def test_start_muted_and_only_explicit_unmute_plays(self):
        self.assertEqual(self.session.state, 'idle')
        self.session.start()
        self.assertEqual(self.session.state, 'preparing')
        self.advance()
        self.assertEqual(self.session.state, 'readyMuted')
        self.assertEqual(self.session.gain, 10)
        self.session.request(self.request('unmute'))
        self.assertEqual(self.session.state, 'playing')
        self.session.stop()
        self.assertTrue(self.graphs[0].terminated)

    def test_stale_unmute_rejected_after_mute(self):
        self.ready()
        stale = self.request('unmute')
        self.session.mute()
        with self.assertRaisesRegex(ValueError, 'Stale'):
            self.session.request(stale)

    def test_udp_loss_with_healthy_control_rebuilds_without_unmute(self):
        self.ready()
        self.session.request(self.request('unmute'))
        self.now += 0.25
        self.session.last_heartbeat = self.now
        self.session.tick()
        self.assertEqual(self.session.state, 'recoveringMuted')
        self.assertTrue(self.graphs[0].terminated)
        self.ingress.close.assert_called()
        self.session.rebuild()
        self.ingress.filter.reset_reception()
        self.advance()
        self.assertEqual(self.session.state, 'readyMuted')
        self.assertTrue(self.session.muted)

    def test_control_loss_with_healthy_udp_mutes_at_three_seconds(self):
        self.ready()
        self.session.request(self.request('unmute'))
        self.advance(3.01, heartbeat=False)
        self.assertEqual(self.session.state, 'recoveringMuted')
        self.assertTrue(self.graphs[0].terminated)

    def test_explicit_disconnect_recovers_immediately(self):
        self.ready()
        self.session.request(self.request('disconnect'))
        self.assertEqual(self.session.state, 'recoveringMuted')

    def test_lease_requires_fresh_start(self):
        self.ready()
        self.now += 12.01
        self.session.tick()
        self.assertEqual(self.session.state, 'recoveryPending')
        self.assertTrue(self.session.closed.is_set())

    def test_pause_silent_packets_remain_ready_but_stopped_packets_recover(self):
        self.ready()
        self.advance(2)
        self.assertEqual(self.session.state, 'readyMuted')
        self.now += 0.3
        self.session.tick()
        self.assertEqual(self.session.state, 'recoveringMuted')

    def test_sender_identity_change_requires_fresh_start(self):
        self.ready()
        self.ingress.filter.accept(packet(800, source_id=43), ('127.0.0.1', 50000))
        self.session.tick()
        self.assertEqual(self.session.state, 'recoveryPending')

    def test_protocol_mismatch_mutes_then_stops(self):
        self.ready()
        with self.assertRaises(ValueError):
            self.session.request(dict(self.request('heartbeat'), version=2))
        self.assertEqual(self.session.state, 'recoveryPending')
        self.assertTrue(self.graphs[0].terminated)
        self.session.request(dict(self.request('status'), version=2))

    def test_full_range_gain_changes_preserve_mute_and_confirm_each_target(self):
        self.ready()
        for muted in (True, False):
            if not muted:
                self.session.request(self.request('unmute'))
            for percent in (90, 0, 100, 35):
                with self.subTest(muted=muted, percent=percent):
                    result = self.session.request(self.request('volume', percent=percent))
                    self.assertEqual(result['percent'], percent)
                    self.assertEqual(result['muted'], muted)
                    self.assertEqual(self.graphs[0].volume, percent)
                    self.assertEqual(self.graphs[0].muted, muted)

    def test_gain_range_and_readback(self):
        self.ready()
        for percent in (-1, 101, True, 12.5):
            with self.subTest(percent=percent), self.assertRaises(ValueError):
                self.session.request(self.request('volume', percent=percent))
        self.session.request(self.request('volume', percent=20))
        self.assertEqual(self.session.gain, 20)
        self.assertTrue(self.session.muted)
        self.session.request(self.request('volume', percent=0))

    def test_mute_bypasses_lifecycle_and_busy_gain(self):
        self.ready()
        self.session.lifecycle.acquire()
        self.session.controls.acquire()
        started = time.monotonic()
        try:
            result = self.session.mute()
        finally:
            self.session.lifecycle.release()
            self.session.controls.release()
        self.assertLess(time.monotonic() - started, 0.25)
        self.assertIsNone(result['muted'])
        self.assertTrue(result['worker_terminated'])

    def test_failed_mute_terminates_audio_without_claiming_readback(self):
        self.ready()
        self.graphs[0].fail_mute = True
        result = self.session.mute()
        self.assertIsNone(result['muted'])
        self.assertTrue(result['worker_terminated'])
        self.assertEqual(result['state'], 'recoveryPending')

    def test_heartbeat_gap_while_the_first_graph_builds_does_not_recover(self):
        def slow_factory(port):
            graph = FakeGraph()
            self.graphs.append(graph)
            original_start = graph.start

            def start():
                # The control channel is still connecting while PipeWire negotiates, so no heartbeat can land yet.
                self.now += 3.5
                self.session.tick()
                original_start()
            graph.start = start
            return graph
        self.session.graph_factory = slow_factory
        self.session.start()
        self.assertEqual(self.session.state, 'preparing')
        self.assertFalse(self.graphs[0].terminated)
        self.assertFalse(self.session.closed.is_set())
        self.advance()
        self.assertEqual(self.session.state, 'readyMuted')

    def test_mute_while_the_first_graph_builds_confirms_without_termination(self):
        results = []

        def slow_factory(port):
            graph = FakeGraph()
            self.graphs.append(graph)
            original_start = graph.start

            def start():
                results.append(self.session.mute())
                original_start()
            graph.start = start
            return graph
        self.session.graph_factory = slow_factory
        self.session.start()
        self.assertTrue(results[0]['muted'])
        self.assertFalse(results[0]['worker_terminated'])
        self.assertEqual(self.session.state, 'preparing')
        self.ingress.close_gate.assert_called()
        self.advance()
        self.assertEqual(self.session.state, 'readyMuted')

    def test_startup_deadline_without_packets(self):
        self.session.start()
        self.now = 60
        self.session.last_heartbeat = self.now
        self.session.tick()
        self.assertEqual(self.session.state, 'recoveryPending')

    def test_loss_during_muted_startup_discards_the_partial_buffer(self):
        self.session.start()
        self.advance(0.1)
        self.assertEqual(self.session.state, 'preparing')
        self.now += 0.251
        self.session.tick()
        self.assertEqual(self.session.state, 'recoveringMuted')
        self.assertTrue(self.graphs[0].terminated)
        self.assertEqual(self.session.phase_deadline, 60)

    def test_repeated_recovery_gaps_do_not_extend_the_deadline(self):
        self.ready()
        self.session.begin_recovery('packet loss')
        original_deadline = self.session.phase_deadline
        self.session.rebuild()
        self.ingress.filter.reset_reception()
        self.advance(0.1)
        self.now += 0.251
        self.session.tick()
        self.assertEqual(self.session.phase_deadline, original_deadline)
        self.assertTrue(self.graphs[-1].terminated)

    def test_failed_graph_recreation_rolls_back(self):
        self.session.graph_factory = Mock(side_effect=RuntimeError('no ALSA'))
        self.session.start()
        self.assertEqual(self.session.state, 'recoveryPending')


if __name__ == '__main__':
    unittest.main()
