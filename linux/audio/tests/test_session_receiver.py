import json
from pathlib import Path
import subprocess
import sys
import threading
import struct
from unittest.mock import patch
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from session_control import PipeWireControl
from session_graph import SessionOutputGraph
from ingress import Ingress, PacketFilter
from session_receiver import SessionReceiver


class SessionReceiverTests(unittest.TestCase):
    def test_an_enabled_rtp_input_accepts_its_first_packet_after_network_recovery(self):
        graph = object.__new__(SessionOutputGraph)
        graph.guard = threading.RLock()
        process = SimpleNamespace(poll=lambda: None)
        packet_filter = PacketFilter('127.0.0.1', 10, clock=lambda: 20)
        graph.inputs = {'rtp': {'sessionId': 'session', 'process': process,
                                'ingress': SimpleNamespace(filter=packet_filter)}}
        packet = struct.pack('!BBHII', 128, 127, 1, 120, 10) + bytes(480)
        self.assertFalse(packet_filter.accept(packet, ('127.0.0.1', 4000)))
        with patch('session_graph.time.monotonic', return_value=20):
            graph.ensure_rtp('session', {'id': 'rtp'})
        self.assertTrue(packet_filter.accept(packet, ('127.0.0.1', 4000)))
        self.assertIs(process, graph.inputs['rtp']['process'])

    def test_a_new_session_reuses_the_existing_stream_process(self):
        graph = object.__new__(SessionOutputGraph)
        process = SimpleNamespace(poll=lambda: None)
        graph.guard = threading.RLock()
        graph.inputs = {'stream': {'sessionId': 'old', 'process': process, 'missingSince': None}}
        graph.ensure_snapcast('new', {'id': 'stream', 'endpoint': 'stream'})
        self.assertEqual('new', graph.inputs['stream']['sessionId'])
        self.assertIs(process, graph.inputs['stream']['process'])

    def receiver(self, graph, receiving=True):
        receiver = SessionReceiver({'state_id': 'home', 'speaker_id': 'speaker', 'physical_id': 'physical',
                                    'boot_sequence': 1}, graph, lambda status: None)
        graph.item['receiving'] = receiving
        configuration = {'protocolVersion': 3, 'stateId': 'home', 'generation': 1, 'revision': 1,
                         'playbackActivated': True, 'groups': [{'id': 'group', 'speakerIds': ['speaker'],
                                                              'enabledSources': ['spotify'], 'muted': False}]}
        session = {'id': 'new', 'ownerId': 'person', 'source': 'spotify', 'destination': 'house',
                   'claimSequence': 2, 'claimed': True, 'eligible': True, 'state': 'playing',
                   'transports': [{'id': 'stream', 'kind': 'snapcast', 'endpoint': 'stream', 'available': True}]}
        catalogue = {'protocolVersion': 3, 'stateId': 'home', 'generation': 1, 'revision': 2,
                     'configurationRevision': 1, 'profiles': [],
                     'sessions': [dict(session, id='old', state='ended', eligible=False, transports=[]), session]}
        for kind, payload in [('Configuration', configuration), ('Catalogue', catalogue),
                              ('Gains', {'stateId': 'home', 'generation': 1, 'revision': 1,
                                         'configurationRevision': 1, 'catalogueRevision': 2,
                                         'gains': {'speaker': {'new': .5}}}),
                              ('Bindings', {'stateId': 'home', 'generation': 1, 'revision': 1,
                                            'clients': {'client': 'stream'}})]:
            receiver.receive(kind, payload)
        return receiver

    def test_catalogue_handoff_does_not_remove_a_reused_input(self):
        graph = FakeGraph()
        receiver = self.receiver(graph)
        receiver.tick()
        self.assertEqual([], graph.removed)
        self.assertEqual(('new',), receiver.selected)
        self.assertEqual({'stream': .5}, graph.gains)

    def test_a_silent_input_is_released_after_the_local_grace(self):
        graph = FakeGraph()
        receiver = self.receiver(graph, receiving=False)
        with patch('session_receiver.time.monotonic', return_value=1000):
            receiver.tick()
        self.assertEqual(('new',), receiver.selected)
        with patch('session_receiver.time.monotonic', return_value=1003):
            receiver.tick()
        self.assertEqual((), receiver.selected)
        self.assertEqual('playback unavailable', receiver.reasons['new'])

    def test_a_failed_audio_operation_is_retried_without_stopping(self):
        for error in (RuntimeError('confirmation timeout'), subprocess.CalledProcessError(1, 'pw-link'),
                      TimeoutError(), StopIteration()):
            graph = FakeGraph(failures=[error])
            receiver = self.receiver(graph)
            receiver.step()
            self.assertIn(type(error).__name__, receiver.error)
            self.assertEqual({}, graph.gains)
            receiver.step()
            self.assertIsNone(receiver.error)
            self.assertEqual({'stream': .5}, graph.gains)
            self.assertEqual(0, graph.starts)

    def test_a_broken_output_graph_is_rebuilt(self):
        graph = FakeGraph(failures=[RuntimeError('status connection failed')], healthy=False)
        receiver = self.receiver(graph)
        receiver.step()
        self.assertEqual(1, graph.starts)
        receiver.step()
        self.assertIsNone(receiver.error)

    def test_a_missing_stage_is_removed_so_it_can_be_created_again(self):
        graph = object.__new__(SessionOutputGraph)
        graph.guard = threading.RLock()
        graph.control = None
        destroyed = []
        graph.command = lambda *arguments: destroyed.append(arguments)
        graph.objects = lambda: []
        process = SimpleNamespace(poll=lambda: None, terminate=lambda: None, wait=lambda timeout=None: 0)
        graph.inputs = {'stream': {'sessionId': 'session', 'node': 'syren_gain_missing', 'process': process,
                                   'muted': True, 'gain': 0.0, 'missingSince': None}}
        graph.orphans = set()
        graph.repair_links()
        self.assertEqual({}, graph.inputs)
        self.assertEqual([], destroyed)

    def test_a_stage_whose_mute_failed_is_still_destroyed(self):
        graph = object.__new__(SessionOutputGraph)
        graph.guard = threading.RLock()
        graph.orphans = set()
        stage = {'id': 42, 'info': {'props': {'node.name': 'syren_gain_audible'}}}
        graph.objects = lambda: [stage]
        destroyed = []

        def command(*arguments):
            destroyed.append(arguments)
            if len(destroyed) == 1:
                raise subprocess.CalledProcessError(1, 'pw-cli')

        def gain(*arguments):
            raise RuntimeError('PipeWire did not confirm the requested change')

        graph.command = command
        graph.control = SimpleNamespace(gain=gain)
        process = SimpleNamespace(poll=lambda: 0)
        graph.inputs = {'stream': {'node': 'syren_gain_audible', 'process': process, 'muted': False}}
        with self.assertRaises(RuntimeError):
            graph.remove('stream')
        self.assertEqual({}, graph.inputs)
        self.assertEqual([('pw-cli', 'destroy', '42')], destroyed)
        self.assertEqual({'syren_gain_audible'}, graph.orphans)
        graph.repair_links()
        self.assertEqual(2, len(destroyed))
        self.assertEqual(set(), graph.orphans)

    def test_a_failed_rtp_input_leaves_no_stage_or_process_behind(self):
        graph = object.__new__(SessionOutputGraph)
        graph.guard = threading.RLock()
        graph.inputs = {}
        graph.orphans = set()
        commands = []
        graph.command = lambda *arguments: commands.append(arguments)
        created = []
        graph.find_node = lambda name, objects=None: {'id': 42} if name in created else None
        stopped = []
        process = SimpleNamespace(poll=lambda: None if not stopped else 0,
                                  terminate=lambda: stopped.append(True), wait=lambda timeout=None: 0)
        graph.spawn = lambda command, environment=None: process
        original_create_stage = SessionOutputGraph.create_stage

        def create_stage(node_name):
            created.append(node_name)
            original_create_stage(graph, node_name)

        graph.create_stage = create_stage
        with self.assertRaises(ValueError):
            graph.ensure_rtp('pc', {'id': 'rtp', 'endpoint': 'rtp://192.168.1.20@0.0.0.0:46000'})
        self.assertEqual([], commands)
        with patch.object(Ingress, 'prepare', return_value=5000), \
                patch.object(Ingress, 'open', side_effect=OSError(99, 'Cannot assign requested address')):
            with self.assertRaises(OSError):
                graph.ensure_rtp('pc', {'id': 'rtp', 'endpoint': 'rtp://192.168.1.20@192.168.1.99:46000'})
        self.assertEqual({}, graph.inputs)
        self.assertEqual([True], stopped)
        self.assertEqual(('pw-cli', 'destroy', '42'), commands[-1])
        self.assertEqual(set(), graph.orphans)

    def test_a_failing_rtp_input_does_not_silence_other_sessions(self):
        graph = FailingRtpGraph()
        receiver = SessionReceiver({'state_id': 'home', 'speaker_id': 'speaker', 'physical_id': 'physical',
                                    'boot_sequence': 1}, graph, lambda status: None)
        configuration = {'protocolVersion': 3, 'stateId': 'home', 'generation': 1, 'revision': 1,
                         'playbackActivated': True, 'groups': [{'id': 'group', 'speakerIds': ['speaker'],
                                                              'enabledSources': ['spotify', 'laptop'], 'muted': False}]}
        spotify = {'id': 'spotify', 'ownerId': 'person', 'source': 'spotify', 'destination': 'house',
                   'claimSequence': 2, 'claimed': True, 'eligible': True, 'state': 'playing',
                   'transports': [{'id': 'stream', 'kind': 'snapcast', 'endpoint': 'stream', 'available': True}]}
        laptop = dict(spotify, id='pc', source='laptop', claimSequence=3, transports=[
            {'id': 'rtp', 'kind': 'rtp', 'speakerId': 'speaker', 'available': True,
             'endpoint': 'rtp://192.168.1.20@192.168.1.99:46000'}])
        catalogue = {'protocolVersion': 3, 'stateId': 'home', 'generation': 1, 'revision': 1,
                     'configurationRevision': 1, 'profiles': [], 'sessions': [spotify, laptop]}
        for kind, payload in [('Configuration', configuration), ('Catalogue', catalogue),
                              ('Gains', {'stateId': 'home', 'generation': 1, 'revision': 1,
                                         'configurationRevision': 1, 'catalogueRevision': 1,
                                         'gains': {'speaker': {'spotify': .5, 'pc': .5}}}),
                              ('Bindings', {'stateId': 'home', 'generation': 1, 'revision': 1,
                                            'clients': {'client': 'stream'}})]:
            receiver.receive(kind, payload)
        for now, attempts in ((1000, 1), (1001, 1), (1002.5, 2), (1004.5, 3)):
            with patch('session_receiver.time.monotonic', return_value=now):
                receiver.step()
            self.assertIsNone(receiver.error)
            self.assertEqual(attempts, graph.rtp_attempts)
        self.assertEqual(('spotify',), receiver.selected)
        self.assertEqual('playback unavailable', receiver.reasons['pc'])
        self.assertEqual({'stream': .5}, graph.gains)

    def test_the_monitor_keeps_a_character_split_across_reads(self):
        control = object.__new__(PipeWireControl)
        control.condition = threading.Condition()
        control.nodes = {}
        control.failure = None
        control.stopped = False
        control.monitor = SimpleNamespace(stdout=SimpleNamespace(fileno=lambda: 0))
        update = json.dumps([{'id': 7, 'info': {'props': {'node.name': 'Café'}}}], ensure_ascii=False).encode()
        split = update.index('é'.encode()) + 1
        chunks = [update[:split], update[split:], b'']
        with patch('session_control.os.read', side_effect=lambda descriptor, size: chunks.pop(0)):
            control.read_monitor()
        self.assertEqual('Café', control.nodes[7]['info']['props']['node.name'])
        self.assertEqual('RuntimeError', control.failure)


class RealtimeTests(unittest.TestCase):
    def test_priorities_follow_the_service_limit(self):
        import session_graph
        with patch('session_graph.os.geteuid', return_value=1000), \
                patch('session_graph.resource.getrlimit', return_value=(88, 88)):
            self.assertEqual(['chrt', '--fifo', '86', 'snapclient'], session_graph.realtime_command(['snapclient'], 86))
            self.assertEqual(88, session_graph.realtime_priority(95))
        with patch('session_graph.os.geteuid', return_value=1000), \
                patch('session_graph.resource.getrlimit', return_value=(0, 0)):
            self.assertEqual(['snapclient'], session_graph.realtime_command(['snapclient'], 86))

    def test_configuration_priority_is_set_once(self):
        from session_graph import with_priority
        self.assertEqual('    args = {\n        rt.prio = 87\n', with_priority('    args = {\n        #rt.prio      = 83\n', 87))
        self.assertEqual('args = { rt.prio = 87 }', with_priority('args = { rt.prio = 82 }', 87))


class FakeGraph:
    def __init__(self, failures=(), healthy=True):
        self.item = {'sessionId': 'old', 'transportId': 'stream', 'clientId': 'client',
                     'endpoint': 'stream', 'receiving': True, 'muted': True, 'gain': 0}
        self.removed = []
        self.gains = {}
        self.failures = list(failures)
        self.is_healthy = healthy
        self.starts = 0

    def healthy(self):
        return self.is_healthy

    def start(self):
        self.starts += 1
        self.is_healthy = True

    def stop(self, cancel=True):
        pass

    def status(self):
        return [dict(self.item)]

    def ensure_snapcast(self, session_id, transport, expect_audio=True):
        self.item['sessionId'] = session_id

    def apply(self, gains):
        if gains and self.failures:
            raise self.failures.pop(0)
        self.gains = gains

    def repair_links(self):
        pass

    def remove(self, identity):
        self.removed.append(identity)


class FailingRtpGraph(FakeGraph):
    def __init__(self):
        super().__init__()
        self.item['sessionId'] = 'spotify'
        self.rtp_attempts = 0

    def ensure_rtp(self, session_id, transport):
        self.rtp_attempts += 1
        raise OSError(99, 'Cannot assign requested address')


if __name__ == '__main__':
    unittest.main()
