import json
import io
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from test_ingress import PacketFilter
from common import atomic_json, deadline, process_identity, run
from compatibility import classify
from pairing import Pairing
import laptop
import receiver
import routing


class LaptopTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        for name in ('ROOT', 'CONFIG', 'RUNTIME'):
            patcher = patch.object(laptop, name, self.directory / name)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(laptop, 'JOURNAL', laptop.ROOT / 'state.json')
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_volume_uses_persistent_control_instead_of_new_ssh(self):
        controller = laptop.Controller()
        self.addCleanup(controller.exiting.set)
        controller.start_complete = True
        controller.state = 'playing'
        controller.session = 'abc'
        controller.receiver = {'generation': 1}
        controller.control = Mock()
        controller.control.request.return_value = {'generation': 1, 'percent': 90}
        controller.pairing = Mock()
        request = {'version': 1, 'action': 'volume', 'session': 'abc', 'generation': 1, 'percent': 90}
        controller.request(request)
        controller.control.request.assert_called_once_with(request, timeout=3)
        controller.pairing.request.assert_not_called()

    def test_failed_control_request_closes_channel_without_replaying(self):
        controller = laptop.Controller()
        self.addCleanup(controller.exiting.set)
        controller.start_complete = True
        controller.state = 'playing'
        controller.session = 'abc'
        controller.receiver = {'generation': 1}
        channel = controller.control = Mock()
        channel.request.side_effect = TimeoutError('lost response')
        controller.pairing = Mock()
        with self.assertRaises(TimeoutError):
            controller.request({'version': 1, 'action': 'volume', 'session': 'abc', 'generation': 1, 'percent': 90})
        channel.close.assert_called_once()
        self.assertIsNone(controller.control)
        self.assertEqual(channel.request.call_count, 1)
        controller.pairing.request.assert_not_called()

    def test_control_channel_accepts_repeated_gain_requests_without_disconnect(self):
        requests = [{'version': 1, 'action': 'volume', 'session': 'abc', 'generation': 1, 'percent': percent}
                    for percent in (90, 5, 100)]
        with patch('sys.argv', ['receiver.py', 'control']),                 patch('sys.stdin', io.StringIO(''.join(json.dumps(request) + '\n' for request in requests))),                 patch('sys.stdout', io.StringIO()) as output,                 patch.object(receiver, 'exchange', side_effect=lambda _, request: request) as exchange:
            receiver.main()
        self.assertEqual([json.loads(line) for line in output.getvalue().splitlines()], requests)
        self.assertEqual(exchange.call_count, 3)

    def test_control_channels_keep_operations_separate(self):
        for channel, action in [('control', 'start'), ('control', 'mute'), ('channel', 'volume'), ('priority', 'volume')]:
            with self.subTest(channel=channel, action=action),                     patch('sys.argv', ['receiver.py', channel]),                     patch('sys.stdin', io.StringIO(json.dumps({'action': action}) + '\n')),                     patch.object(receiver, 'exchange') as exchange:
                with self.assertRaisesRegex(ValueError, 'not allowed'):
                    receiver.main()
                exchange.assert_not_called()

    def test_independent_local_cleanup_runs_when_receiver_is_unreachable(self):
        atomic_json(laptop.JOURNAL, {'session': 'abc', 'remote_start_intended': True, 'endpoint': {}})
        pairing = Mock()
        pairing.request.side_effect = RuntimeError('SSH unavailable')
        with patch.object(routing, 'restore_routes') as routes, patch.object(routing, 'stop_process') as sender, patch.object(routing, 'restore_sender') as snapcast:
            with self.assertRaisesRegex(RuntimeError, 'SSH unavailable'):
                laptop.cleanup(pairing)
        routes.assert_called_once()
        sender.assert_called_once()
        snapcast.assert_called_once()
        self.assertTrue(laptop.JOURNAL.exists())

    def test_shared_receiver_reuses_existing_snapclient_endpoint(self):
        defaults = self.directory / 'snapclient'
        defaults.write_text('SNAPCLIENT_OPTS="-h server.local -p 1705 --player alsa --hostID speaker"\n')
        self.assertEqual(receiver.snapcast_settings({'snapclient_id': 'speaker'}, defaults),
                         {'host': 'server.local', 'port': 1705, 'id': 'speaker'})
        defaults.write_text('SNAPCLIENT_OPTS="-h $(invalid)"\n')
        with self.assertRaises(ValueError):
            receiver.snapcast_settings({'snapclient_id': 'speaker'}, defaults)

    def test_receiver_drain_restores_without_a_broker_socket(self):
        with patch.object(receiver, 'SOCKET', self.directory / 'missing.sock'), \
                patch.object(receiver, 'DISABLED', self.directory / 'disabled'), \
                patch.object(receiver, 'STATE', self.directory / 'state.json'), \
                patch.object(receiver.os, 'geteuid', return_value=0), \
                patch.object(receiver, 'stop_audio') as stop_audio, \
                patch.object(receiver, 'restore') as restore, \
                patch('sys.argv', ['receiver.py', 'drain']):
            receiver.main()
        stop_audio.assert_called_once()
        restore.assert_called_once()

    def test_repeated_cleanup_is_safe(self):
        laptop.cleanup(Mock())
        laptop.cleanup(Mock())
        self.assertFalse(laptop.JOURNAL.exists())

    def test_old_guardian_cannot_clean_a_new_session(self):
        atomic_json(laptop.JOURNAL, {'session': 'new'})
        with patch.object(routing, 'restore_routes') as routes:
            laptop.cleanup(Mock(), expected_session='old')
            routes.assert_not_called()
        self.assertTrue(laptop.JOURNAL.exists())

    def test_pending_recovery_blocks_start(self):
        controller = laptop.Controller()
        self.addCleanup(controller.exiting.set)
        controller.state = 'recoveryPending'
        with self.assertRaisesRegex(ValueError, 'reconcile'):
            controller.request({'version': 1, 'action': 'start', 'app_pid': os.getpid()})

    def test_restart_does_not_auto_start_opted_in_pairing(self):
        pairing = Pairing(laptop.CONFIG)
        pairing.opt_in(True)
        controller = laptop.Controller()
        self.addCleanup(controller.exiting.set)
        self.assertEqual(controller.state, 'idle')
        self.assertTrue(controller.status()['preferences']['opt_in'])
        self.assertIsNone(controller.owner)

    def test_start_reply_identifies_the_session_before_background_preflight(self):
        controller = laptop.Controller()
        self.addCleanup(controller.exiting.set)
        controller.pairing.opt_in(True)
        with patch.object(controller, 'start'):
            response = controller.request({'version': 1, 'action': 'start', 'app_pid': os.getpid()})
        self.assertEqual(response['state'], 'preparing')
        self.assertRegex(response['session'], r'^[0-9a-f]{32}$')
        self.assertEqual(response['session'], controller.session)

    def test_window_close_ends_only_its_owner(self):
        controller = laptop.Controller()
        self.addCleanup(controller.exiting.set)
        controller.owner = process_identity(os.getpid())
        controller.app_heartbeat = time.monotonic()
        with patch.object(controller, 'stop') as stop:
            controller.request({'action': 'close', 'app_pid': os.getpid() + 1})
            stop.assert_not_called()
            controller.request({'action': 'close', 'app_pid': os.getpid()})
            for count in range(20):
                if stop.called:
                    break
                time.sleep(0.005)
            stop.assert_called_once()

    def test_app_timeout_stops_with_no_receiver_heartbeat_dependency(self):
        controller = laptop.Controller()
        self.addCleanup(controller.exiting.set)
        with patch.object(controller, 'stop') as stop:
            controller.app_heartbeat = time.monotonic() - 3
            controller.owner = process_identity(os.getpid())
            time.sleep(0.12)
            stop.assert_called_once()

    def test_manual_default_and_stream_changes_survive(self):
        wanted = {'default': 'speakers', 'streams': {'7': {'sink': 'speakers', 'serial': 'one'},
                                                   '8': {'sink': 'speakers', 'serial': 'two'}}}
        current = {'default': 'headphones', 'sinks': {1: 'speakers', 2: 'headphones', 3: routing.LIVE_SINK},
                   'streams': {'7': {'sink': 'headphones', 'serial': 'one'},
                               '8': {'sink': routing.LIVE_SINK, 'serial': 'reused'}}}
        with patch.object(routing, 'snapshot', return_value=current), patch.object(routing, 'run') as command:
            command.return_value.returncode = 0
            routing.apply_snapshot(wanted, routing.LIVE_SINK)
            command.assert_not_called()

    def test_matching_owned_routes_are_restored_without_gains(self):
        wanted = {'default': 'speakers', 'streams': {'7': {'sink': 'speakers', 'serial': 'one'}}}
        current = {'default': routing.LIVE_SINK, 'sinks': {1: 'speakers', 3: routing.LIVE_SINK},
                   'streams': {'7': {'sink': routing.LIVE_SINK, 'serial': 'one'}}}
        with patch.object(routing, 'snapshot', return_value=current), patch.object(routing, 'run') as command:
            command.return_value.returncode = 0
            routing.apply_snapshot(wanted, routing.LIVE_SINK)
            self.assertEqual([call.args[0] for call in command.call_args_list], [
                ['pactl', 'set-default-sink', 'speakers'], ['pactl', 'move-sink-input', '7', 'speakers']])

    def test_lost_live_sink_restores_the_default_and_relinked_streams(self):
        wanted = {'default': 'speakers', 'streams': {'7': {'sink': 'headphones', 'serial': 'one'},
                                                   '8': {'sink': 'speakers', 'serial': 'two'}}}
        current = {'default': 'speakers', 'sinks': {1: 'speakers', 2: 'headphones'},
                   'streams': {'7': {'sink': 'speakers', 'serial': 'one'},
                               '8': {'sink': 'headphones', 'serial': 'two'}}}
        with patch.object(routing, 'snapshot', return_value=current), patch.object(routing, 'run') as command:
            command.return_value.returncode = 0
            routing.apply_snapshot(wanted, routing.LIVE_SINK)
            self.assertEqual([call.args[0] for call in command.call_args_list], [
                ['pactl', 'set-default-sink', 'speakers'], ['pactl', 'move-sink-input', '7', 'headphones']])

    def test_lost_live_sink_with_lost_original_pins_the_fallback_default(self):
        wanted = {'default': 'dock', 'streams': {}}
        current = {'default': 'speakers', 'sinks': {1: 'speakers'}, 'streams': {}}
        with patch.object(routing, 'snapshot', return_value=current), patch.object(routing, 'run') as command:
            command.return_value.returncode = 0
            routing.apply_snapshot(wanted, routing.LIVE_SINK)
            self.assertEqual([call.args[0] for call in command.call_args_list], [['pactl', 'set-default-sink', 'speakers']])

    def test_commands_cancel_and_have_deadlines(self):
        started = time.monotonic()
        with self.assertRaises(TimeoutError), deadline(0.08):
            run(['sleep', '20'])
        self.assertLess(time.monotonic() - started, 0.25)


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.pairing = Pairing(Path(self.temporary.name))

    def test_discovery_resolves_snapclient_hostname_without_pairing_or_login(self):
        with patch.object(self.pairing, 'resolve', return_value='192.168.1.5') as resolve, patch('pairing.pwd.getpwuid', return_value=Mock(pw_name='listener')):
            defaults = self.pairing.discover({'snapclient_id': 'speaker', 'name': 'livingroom'})
        resolve.assert_called_once_with('livingroom.local')
        self.assertEqual(defaults['host'], 'livingroom.local')
        self.assertEqual(defaults['address'], '192.168.1.5')
        self.assertEqual(defaults['user'], 'listener')
        self.assertEqual(defaults['key'], '')
        self.assertFalse(self.pairing.path.exists())
        self.assertFalse(self.pairing.known_hosts.exists())

    def test_discovery_preserves_only_the_selected_receivers_saved_details(self):
        saved = {'snapclient_id': 'saved', 'host': 'custom.example', 'user': 'remote',
                 'port': 2222, 'key': '/home/listener/.ssh/receiver'}
        atomic_json(self.pairing.path, {'opt_in': True, 'pairing': saved})
        with patch.object(self.pairing, 'resolve', return_value='192.168.1.5') as resolve:
            defaults = self.pairing.discover({'snapclient_id': 'saved', 'name': 'livingroom'})
            resolve.assert_not_called()
            for field in ('host', 'user', 'port', 'key'):
                self.assertEqual(defaults[field], saved[field])
            defaults = self.pairing.discover({'snapclient_id': 'different', 'name': 'kitchen'})
        self.assertEqual(defaults['host'], 'kitchen.local')
        self.assertEqual(defaults['port'], 22)
        self.assertEqual(defaults['key'], '')

    def test_unresolvable_discovery_leaves_address_editable(self):
        with patch.object(self.pairing, 'resolve', side_effect=subprocess.CalledProcessError(2, ['getent'])):
            defaults = self.pairing.discover({'snapclient_id': 'speaker', 'name': 'livingroom'})
        self.assertEqual(defaults['host'], '')
        self.assertIn('Enter its SSH address', defaults['message'])

    def test_discovery_does_not_resolve_arbitrary_display_text(self):
        with patch.object(self.pairing, 'resolve') as resolve:
            defaults = self.pairing.discover({'snapclient_id': 'speaker', 'name': '$(touch /tmp/command)'})
        resolve.assert_not_called()
        self.assertEqual(defaults['host'], '')

    def test_ssh_is_strict_pinned_and_noninteractive(self):
        arguments = self.pairing.arguments({'alias': 'syren-abc', 'port': 22, 'user': 'listener',
                                            'key': '/home/listener/.ssh/key', 'address': '192.168.1.5'}, ['status'])
        self.assertIn('BatchMode=yes', arguments)
        self.assertIn('StrictHostKeyChecking=yes', arguments)
        self.assertIn('HostKeyAlias=syren-abc', arguments)
        self.assertIn('IdentitiesOnly=yes', arguments)
        self.assertEqual(arguments[-2], '192.168.1.5')

    def test_changed_key_needs_explicit_repair(self):
        candidate = {'host': 'speaker', 'user': 'listener', 'port': 22, 'address': '192.168.1.5',
                     'fingerprint': 'SHA256:verified', 'key_line': 'syren-abc ssh-ed25519 value\n',
                     'challenge': 'proof', 'expires': time.time() + 300, 'changed_key': True}
        atomic_json(self.pairing.candidate_path, candidate)
        request = {'challenge': 'proof', 'verified_fingerprint': 'SHA256:verified'}
        with self.assertRaisesRegex(ValueError, 'Changed host key'):
            self.pairing.confirm(request)
        self.assertFalse(self.pairing.known_hosts.exists())
        self.pairing.confirm(dict(request, repair_changed_key=True))
        self.assertEqual(self.pairing.known_hosts.read_text(), candidate['key_line'])

    def test_wrong_fingerprint_cannot_pin(self):
        atomic_json(self.pairing.candidate_path, {'expires': time.time() + 300,
                     'challenge': 'proof', 'fingerprint': 'SHA256:actual'})
        with self.assertRaises(ValueError):
            self.pairing.confirm({'challenge': 'proof', 'verified_fingerprint': 'SHA256:wrong'})

    def test_credentials_error_is_actionable(self):
        with patch.object(self.pairing, 'arguments', return_value=['ssh']), patch('pairing.run', return_value=subprocess.CompletedProcess([], 255, '', 'denied')):
            with self.assertRaisesRegex(RuntimeError, 'unlock.*terminal'):
                self.pairing.request({}, {})

    def test_compatibility_classes_are_not_conflated(self):
        self.assertEqual(classify('1.4.2')['class'], 'tested')
        self.assertEqual(classify('1.5.99')['class'], 'untested')
        self.assertEqual(classify('bad', {'versions': {'bad': {'class': 'known incompatible'}}})['class'], 'known incompatible')
        self.assertEqual(classify('empty', {'versions': {'empty': {'class': 'tested'}}})['class'], 'untested')


class ReceiverRestoreTests(unittest.TestCase):
    def test_stale_worker_cleanup_does_not_touch_a_new_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            journal = Path(temporary) / 'state.json'
            atomic_json(journal, {'session': 'new'})
            broker = object.__new__(receiver.Broker)
            broker.lock = threading.Lock()
            broker.cancel = threading.Event()
            with patch.object(receiver, 'STATE', journal), patch.object(receiver, 'restore') as restore:
                broker.cleanup('old')
                restore.assert_not_called()
                self.assertFalse(broker.cancel.is_set())

    def test_ambiguous_handoff_stays_pending(self):
        with tempfile.TemporaryDirectory() as temporary:
            journal = Path(temporary) / 'state.json'
            atomic_json(journal, {'session': 'abc', 'snap_stop_intended': True})
            with patch.object(receiver, 'STATE', journal), patch.object(receiver, 'stop_audio'), patch.object(receiver, 'service_state', return_value={'ActiveState': 'inactive'}), patch.object(receiver, 'run') as command:
                with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
                    receiver.restore()
                command.assert_not_called()
                self.assertTrue(journal.exists())

    def test_owned_snapclient_is_restored_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            journal = Path(temporary) / 'state.json'
            stopped = {'ActiveState': 'inactive', 'InactiveEnterTimestampMonotonic': '100'}
            atomic_json(journal, {'session': 'abc', 'snap_stop_intended': True, 'snap_stopped': stopped})
            with patch.object(receiver, 'STATE', journal), patch.object(receiver, 'stop_audio'), patch.object(receiver, 'service_state', side_effect=[stopped, {'ActiveState': 'active'}]), patch.object(receiver, 'run') as command:
                receiver.restore()
                receiver.restore()
                command.assert_called_once()
                self.assertFalse(journal.exists())


if __name__ == '__main__':
    unittest.main()
