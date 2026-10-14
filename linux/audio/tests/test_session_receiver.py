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

    def test_casting_snapcast_session_is_bound_and_warm_like_spotify(self):
        graph = FakeGraph()
        graph.item.update(transportId='airplay-kantoor', endpoint='airplay-kantoor')
        ensured = []

        def ensure_snapcast(session_id, transport, expect_audio=True):
            graph.item['sessionId'] = session_id
            ensured.append((session_id, transport['id'], expect_audio))

        graph.ensure_snapcast = ensure_snapcast
        receiver = SessionReceiver({'state_id': 'home', 'speaker_id': 'speaker', 'physical_id': 'physical',
                                    'boot_sequence': 1}, graph, lambda status: None)
        configuration = {'protocolVersion': 3, 'stateId': 'home', 'generation': 1, 'revision': 1,
                         'playbackActivated': True, 'groups': [{'id': 'group', 'speakerIds': ['speaker'],
                                                              'enabledSources': ['spotify', 'casting'], 'muted': False}]}
        session = {'id': 'cast', 'ownerId': 'guest:' + 'a' * 64, 'source': 'casting', 'protocol': 'airplay',
                   'senderId': 'a' * 64, 'destination': 'group', 'claimSequence': 2, 'claimed': True,
                   'eligible': True, 'state': 'playing',
                   'transports': [{'id': 'airplay-kantoor', 'kind': 'snapcast', 'endpoint': 'airplay-kantoor',
                                   'available': True}]}
        catalogue = {'protocolVersion': 3, 'stateId': 'home', 'generation': 1, 'revision': 2,
                     'configurationRevision': 1, 'profiles': [], 'sessions': [session]}
        for kind, payload in [('Configuration', configuration), ('Catalogue', catalogue),
                              ('Gains', {'stateId': 'home', 'generation': 1, 'revision': 1,
                                         'configurationRevision': 1, 'catalogueRevision': 2,
                                         'gains': {'speaker': {'cast': .5}}}),
                              ('Bindings', {'stateId': 'home', 'generation': 1, 'revision': 1,
                                            'clients': {'client': 'airplay-kantoor'}})]:
            receiver.receive(kind, payload)
        with patch('session_receiver.time.monotonic', return_value=1000):
            receiver.tick()
        self.assertEqual(('cast',), receiver.selected)
        self.assertEqual({'airplay-kantoor': .5}, graph.gains)
        self.assertEqual(('cast', 'airplay-kantoor', True), ensured[-1])
        receiver.state.messages['Catalogue']['sessions'][0].update(state='paused', eligible=False)
        for now in (1001, 1010):
            with patch('session_receiver.time.monotonic', return_value=now):
                receiver.tick()
        self.assertEqual((), receiver.selected)
        self.assertEqual({}, graph.gains)
        self.assertEqual([], graph.removed)
        self.assertEqual(('cast', 'airplay-kantoor', False), ensured[-1])

    def receiver(self, graph, receiving=True):
        receiver = SessionReceiver({'state_id': 'home', 'speaker_id': 'speaker', 'physical_id': 'physical',
                                    'boot_sequence': 1}, graph, lambda status: None)
        if isinstance(graph, FakeGraph):
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

    def test_an_interrupt_keeps_the_gain_of_a_healthy_input_during_the_server_grace(self):
        graph = FakeGraph()
        receiver = self.receiver(graph)
        receiver.tick()
        session = receiver.state.messages['Catalogue']['sessions'][1]
        self.assertEqual({'stream': .5}, graph.gains)
        # When the producer interrupts, the server keeps the session eligible and playing for its grace.
        session['transports'][0]['available'] = False
        receiver.tick()
        self.assertEqual({'stream': .5}, graph.gains)
        graph.item['receiving'] = False
        receiver.tick()
        self.assertEqual({}, graph.gains)
        graph.item['receiving'] = True
        session.update(eligible=False)
        receiver.tick()
        self.assertEqual({}, graph.gains)
        self.assertEqual([], graph.removed)

    def paused(self, graph, **changes):
        receiver = self.receiver(graph)
        while not receiver.incoming.empty():
            receiver.state.receive(*receiver.incoming.get())
        session = receiver.state.messages['Catalogue']['sessions'][1]
        session.update(state='paused', eligible=False, claimed=False, **changes)
        return receiver, session

    def test_a_paused_session_keeps_its_input_while_it_is_in_scope(self):
        for available in (True, False):
            with self.subTest(available=available):
                graph = FakeGraph()
                receiver, session = self.paused(graph)
                session['transports'][0]['available'] = available
                # A newer paused session from another receiver takes the warm slot for Spotify.
                receiver.state.messages['Catalogue']['sessions'].append(dict(
                    session, id='newer', claimSequence=3,
                    transports=[{'id': 'other', 'kind': 'snapcast', 'endpoint': 'other', 'available': True}]))
                for now in (1000, 1004, 1040, 1100):
                    with patch('session_receiver.time.monotonic', return_value=now):
                        receiver.tick()
                self.assertEqual([], graph.removed)
                self.assertIn(('new', 'stream', False), graph.ensured)
                self.assertNotIn(('new', 'stream', True), graph.ensured)

    def test_an_ended_or_moved_paused_session_is_still_removed_promptly(self):
        for changes in ({'state': 'ended'}, {'destination': 'elsewhere'}):
            with self.subTest(changes=changes):
                graph = FakeGraph()
                receiver, session = self.paused(graph)
                with patch('session_receiver.time.monotonic', return_value=1000):
                    receiver.tick()
                self.assertEqual([], graph.removed)
                session.update(changes)
                with patch('session_receiver.time.monotonic', return_value=1000.1):
                    receiver.tick()
                self.assertEqual(['stream'], graph.removed)
        graph = FakeGraph()
        receiver, session = self.paused(graph)
        receiver.state.messages['Configuration']['groups'][0]['enabledSources'] = ['laptop']
        with patch('session_receiver.time.monotonic', return_value=1000):
            receiver.tick()
        self.assertEqual(['stream'], graph.removed)

    def test_a_long_pause_resumes_on_the_same_snapclient(self):
        graph, process, spawned, removed = snapcast_graph()
        stage = {'id': 7, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'syren_gain_stream'}}}
        graph.objects = lambda: [stage]
        graph.orphans = set()
        graph.control = SimpleNamespace(node=lambda name: 7, gain=lambda *arguments: None)
        receiver, session = self.paused(graph)
        session['transports'][0]['available'] = False
        clock = [1000.0]

        def tick_until(end):
            while clock[0] < end:
                with patch('session_receiver.time.monotonic', return_value=clock[0]), \
                        patch('session_graph.time.monotonic', return_value=clock[0]):
                    receiver.tick()
                clock[0] += 0.5

        # Snapclient released its Pulse stream after five seconds without chunks, so no node feeds the stage.
        tick_until(1100)
        self.assertEqual(([], []), (removed, spawned))
        session.update(state='playing', eligible=True, claimed=True)
        session['transports'][0]['available'] = True
        # The first chunk reaches Pulse only after the two second Snapcast buffer and the producer's own start.
        tick_until(1106)
        self.assertEqual(([], []), (removed, spawned))
        self.assertIs(process, graph.inputs['stream']['process'])

    def test_a_playing_session_keeps_its_input_while_its_snapclient_reconnects(self):
        graph = FakeGraph()
        receiver = self.receiver(graph)
        while not receiver.incoming.empty():
            receiver.state.receive(*receiver.incoming.get())
        # Another profile played Spotify later and paused, so it holds the warm Spotify slot.
        receiver.state.messages['Catalogue']['sessions'].append({
            'id': 'other', 'ownerId': 'someone', 'source': 'spotify', 'destination': 'house',
            'claimSequence': 3, 'claimed': True, 'eligible': False, 'state': 'paused',
            'transports': [{'id': 'otherstream', 'kind': 'snapcast', 'endpoint': 'otherstream', 'available': True}]})
        with patch('session_receiver.time.monotonic', return_value=1000):
            receiver.tick()
        self.assertEqual({'stream': .5}, graph.gains)
        # Snapclient dropped its Pulse stream while it reconnects to the server.
        graph.item['receiving'] = False
        for now in (1001, 1004, 1007, 1010):
            with patch('session_receiver.time.monotonic', return_value=now):
                receiver.tick()
        self.assertEqual([], graph.removed)
        self.assertEqual('playback unavailable', receiver.reasons['new'])
        self.assertEqual(('new', 'stream', True), [item for item in graph.ensured if item[0] == 'new'][-1])

    def test_a_reconnecting_snapclient_is_not_replaced(self):
        graph, process, spawned, removed = snapcast_graph()
        graph.inputs['stream']['missingSince'] = 995
        with patch('session_graph.time.monotonic', return_value=1000):
            graph.ensure_snapcast('new', {'id': 'stream', 'endpoint': 'stream'}, expect_audio=True)
        self.assertEqual(([], []), (removed, spawned))
        self.assertIs(process, graph.inputs['stream']['process'])

    def test_a_snapclient_that_stays_without_audio_while_playing_is_replaced(self):
        graph, process, spawned, removed = snapcast_graph()
        graph.inputs['stream']['missingSince'] = 960
        with patch('session_graph.time.monotonic', return_value=1000):
            graph.ensure_snapcast('new', {'id': 'stream', 'endpoint': 'stream'}, expect_audio=False)
        self.assertEqual(([], []), (removed, spawned))
        graph.inputs['stream']['missingSince'] = 960
        with patch('session_graph.time.monotonic', return_value=1000):
            graph.ensure_snapcast('new', {'id': 'stream', 'endpoint': 'stream'}, expect_audio=True)
        self.assertEqual(['stream'], removed)
        self.assertEqual(1, len(spawned))
        self.assertIsNot(process, graph.inputs['stream']['process'])

    def test_a_dead_snapclient_is_replaced_at_once(self):
        graph, process, spawned, removed = snapcast_graph(alive=False)
        with patch('session_graph.time.monotonic', return_value=1000):
            graph.ensure_snapcast('new', {'id': 'stream', 'endpoint': 'stream'}, expect_audio=False)
        self.assertEqual(['stream'], removed)
        self.assertEqual(1, len(spawned))

    def test_forcing_fast_uses_arriving_packets_without_waiting_for_auto_trust(self):
        graph = FakeGraph()
        receiver = self.receiver(graph)
        receiver.tick()
        configuration = receiver.state.messages['Configuration']
        configuration['groups'][0]['enabledSources'] = ['laptop']
        session = receiver.state.messages['Catalogue']['sessions'][1]
        session.update(source='laptop', pcMode='auto')
        session['transports'].append({'id': 'rtp', 'kind': 'rtp', 'speakerId': 'speaker',
                                     'endpoint': 'rtp-path', 'available': True})
        packet_input = {'sessionId': 'new', 'transportId': 'rtp', 'clientId': None,
                        'receiving': True, 'trusted': False, 'muted': True, 'gain': 0}
        graph.status = lambda: [dict(graph.item), dict(packet_input)]
        graph.ensure_rtp = lambda *arguments: None
        receiver.tick()
        self.assertEqual({'stream': .5}, graph.gains)
        session['pcMode'] = 'fast'
        receiver.tick()
        self.assertEqual({'rtp': .5}, graph.gains)
        session['pcMode'] = 'stable'
        receiver.tick()
        self.assertEqual({'stream': .5}, graph.gains)
        self.assertEqual([], graph.removed)

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

    def test_rtp_buffer_covers_two_output_cycles_and_complete_packets(self):
        for requested, expected in [(5, 7.5), (6, 7.5), (8, 10), (20, 20)]:
            with self.subTest(requested=requested):
                graph = object.__new__(SessionOutputGraph)
                graph.guard = threading.RLock()
                graph.inputs = {}
                graph.create_stage = lambda name: None
                commands = []
                process = SimpleNamespace(poll=lambda: None)

                def spawn(command, environment=None):
                    commands.append(command)
                    return process

                graph.spawn = spawn
                with patch.object(Ingress, 'prepare', return_value=5000), \
                        patch.object(Ingress, 'open'), patch('session_graph.run_realtime'):
                    graph.ensure_rtp('pc', {'id': 'rtp', 'endpoint': 'rtp://192.168.1.20@192.168.1.21:46000',
                                           'latencyMsec': requested})
                properties = json.loads(commands[0][-1])
                self.assertEqual(expected, properties['sess.latency.msec'])

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


def snapcast_graph(alive=True):
    # A session graph with one Snapcast input whose PipeWire calls are stubbed.
    graph = object.__new__(SessionOutputGraph)
    graph.guard = threading.RLock()
    graph.physical_id = 'physical'
    graph.directory = Path('/run/syren-test')
    graph.environment = {}
    graph.snapcast_host = 'server'
    graph.snapcast_port = 1704
    graph.create_stage = lambda node_name: None
    spawned = []
    removed = []

    def spawn(command, environment=None):
        spawned.append(command)
        return SimpleNamespace(poll=lambda: None, pid=5000 + len(spawned))

    def remove(identity):
        removed.append(identity)
        graph.inputs.pop(identity)

    graph.spawn = spawn
    graph.remove = remove
    process = SimpleNamespace(poll=lambda: None if alive else 0, pid=4242)
    graph.inputs = {'stream': {'sessionId': 'new', 'transportId': 'stream', 'pcMode': 'auto',
                               'clientId': 'client', 'endpoint': 'stream', 'node': 'syren_gain_stream',
                               'process': process, 'gain': 0.0, 'muted': True, 'receiving': False,
                               'missingSince': None}}
    return graph, process, spawned, removed


class FakeGraph:
    def __init__(self, failures=(), healthy=True):
        self.item = {'sessionId': 'old', 'transportId': 'stream', 'clientId': 'client',
                     'endpoint': 'stream', 'receiving': True, 'muted': True, 'gain': 0}
        self.ensured = []
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
        if transport['id'] == self.item['transportId']:
            self.item['sessionId'] = session_id
        self.ensured.append((session_id, transport['id'], expect_audio))

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
