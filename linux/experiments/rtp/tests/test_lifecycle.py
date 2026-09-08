import copy
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


DIRECTORY = Path(__file__).resolve().parents[1]


def load_module(name, filename):
    loader = importlib.machinery.SourceFileLoader(name, str(DIRECTORY / filename))
    specification = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(specification)
    loader.exec_module(module)
    return module


laptop = load_module('rtp_laptop', 'syren-rtp')
receiver = load_module('rtp_receiver', 'pi.py')


class LaptopLifecycleTests(unittest.TestCase):
    def test_sender_that_ignores_term_is_killed_only_inside_its_unit(self):
        with patch.object(laptop, 'run') as execute, \
                patch.object(laptop, 'service_active', side_effect=['deactivating', 'inactive']), \
                patch.object(laptop.time, 'monotonic', side_effect=[0, 1, 3, 3, 4]), \
                patch.object(laptop.time, 'sleep'):
            laptop.stop_sender()
        self.assertEqual(execute.call_args_list[0].args[0],
                         ['systemctl', '--user', 'stop', '--no-block', laptop.SENDER_SERVICE])
        self.assertEqual(execute.call_args_list[1].args[0],
                         ['systemctl', '--user', 'kill', '--signal=SIGKILL', '--kill-whom=all', laptop.SENDER_SERVICE])

    def test_sender_that_stops_normally_is_not_killed(self):
        with patch.object(laptop, 'run') as execute, \
                patch.object(laptop, 'service_active', return_value='inactive'):
            laptop.stop_sender()
        execute.assert_called_once_with(['systemctl', '--user', 'stop', '--no-block', laptop.SENDER_SERVICE])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.patches = [patch.object(laptop, 'STATE_ROOT', self.directory),
                        patch.object(laptop, 'STATE', self.directory / 'state.json'),
                        patch.object(laptop, 'APP_STATE', self.directory / 'app-state')]
        for replacement in self.patches:
            replacement.start()
        self.initial = {'default': 'speaker', 'sinks': {1: 'speaker', 2: 'headphones', 3: laptop.LIVE_SINK},
                        'streams': {'7': {'sink': 'speaker', 'serial': '70'},
                                    '8': {'sink': 'headphones', 'serial': '80'}}}

    def tearDown(self):
        for replacement in reversed(self.patches):
            replacement.stop()
        self.temporary.cleanup()

    def state(self):
        directory = self.directory / 'session'
        directory.mkdir(exist_ok=True)
        return {'routing': self.initial, 'directory': str(directory),
                'sender_was_active': True, 'sender_changed': True}

    def test_manual_routes_survive_and_new_streams_get_restored_default(self):
        current = copy.deepcopy(self.initial)
        current['default'] = 'headphones'
        current['streams']['7']['sink'] = 'headphones'
        current['streams']['8']['sink'] = laptop.LIVE_SINK
        current['streams']['9'] = {'sink': laptop.LIVE_SINK, 'serial': '90'}
        wanted = laptop.desired_restore(self.state(), current)
        self.assertEqual(wanted['default'], 'headphones')
        self.assertEqual(wanted['streams']['7']['sink'], 'headphones')
        self.assertEqual(wanted['streams']['8']['sink'], 'headphones')
        self.assertEqual(wanted['streams']['9']['sink'], 'headphones')

    def test_reused_stream_id_does_not_receive_old_destination(self):
        current = copy.deepcopy(self.initial)
        current['default'] = laptop.LIVE_SINK
        current['streams']['8'] = {'sink': laptop.LIVE_SINK, 'serial': '800'}
        wanted = laptop.desired_restore(self.state(), current)
        self.assertEqual(wanted['streams']['8']['sink'], 'speaker')

    def test_compare_before_restore_preserves_new_manual_choice(self):
        current = copy.deepcopy(self.initial)
        current['default'] = 'headphones'
        current['streams']['7']['sink'] = 'headphones'
        with patch.object(laptop, 'snapshot', return_value=current), patch.object(laptop, 'run') as execute:
            laptop.apply_snapshot(self.initial, laptop.LIVE_SINK)
        execute.assert_not_called()

    def test_startup_failure_after_sender_stop_restores_once(self):
        state = self.state()
        laptop.write_state(state)
        with patch.object(laptop, 'snapshot', return_value=self.initial), \
                patch.object(laptop, 'apply_snapshot'), \
                patch.object(laptop, 'signal_process'), \
                patch.object(laptop, 'restore_sender') as restore_sender:
            laptop.cleanup()
            laptop.cleanup()
        restore_sender.assert_called_once()
        self.assertFalse(laptop.STATE.exists())
        self.assertTrue((Path(state['directory']) / 'state.json').exists())

    def test_failed_cleanup_retains_journal_for_retry(self):
        laptop.write_state(self.state())
        with patch.object(laptop, 'snapshot', side_effect=RuntimeError('server down')), \
                patch.object(laptop, 'signal_process'), patch.object(laptop, 'restore_sender'):
            with self.assertRaisesRegex(RuntimeError, 'Routing restore'):
                laptop.cleanup()
        self.assertTrue(laptop.STATE.exists())
        self.assertIn('server down', laptop.STATE.read_text())

    def test_sender_restart_reverses_its_initial_routing_and_app_state_write(self):
        state = self.state()
        laptop.APP_STATE.write_text('enabled\nspeaker\n')
        def wait_for_capture():
            laptop.APP_STATE.write_text('enabled\nheadphones\n')
        desired = copy.deepcopy(self.initial)
        desired['default'] = 'headphones'
        with patch.object(laptop, 'snapshot', return_value=desired), \
                patch.object(laptop, 'service_active', return_value='inactive'), \
                patch.object(laptop, 'run') as execute, \
                patch.object(laptop, 'wait_for_sender', side_effect=wait_for_capture), \
                patch.object(laptop, 'apply_snapshot') as restore_routing:
            laptop.restore_sender(state)
        execute.assert_called_once_with(['systemctl', '--user', 'start', laptop.SENDER_SERVICE])
        restore_routing.assert_called_once_with(desired, 'SyrenSystem')
        self.assertEqual(laptop.APP_STATE.read_text(), 'enabled\nspeaker\n')
        self.assertFalse(state['sender_changed'])

    def test_manual_sender_restart_is_left_alone(self):
        with patch.object(laptop, 'service_active', return_value='active'), \
                patch.object(laptop, 'run') as execute:
            laptop.restore_sender(self.state())
        execute.assert_not_called()

    def test_unreachable_pi_does_not_prevent_local_restoration(self):
        state = dict(self.state(), remote_started=True, host='yme@pi', session='0' * 32)
        laptop.write_state(state)
        with patch.object(laptop, 'remote_request', side_effect=RuntimeError('offline')), \
                patch.object(laptop, 'run', side_effect=RuntimeError('offline')), \
                patch.object(laptop, 'snapshot', return_value=self.initial), \
                patch.object(laptop, 'apply_snapshot') as routing, \
                patch.object(laptop, 'signal_process'), \
                patch.object(laptop, 'restore_sender') as sender:
            with self.assertRaisesRegex(RuntimeError, 'Pi restore'):
                laptop.cleanup()
        routing.assert_called_once()
        sender.assert_called_once()
        self.assertTrue(laptop.STATE.exists())

    def test_guardian_cleans_up_when_controller_pipe_closes(self):
        with patch.object(laptop.sys, 'stdin', io.StringIO('')), patch.object(laptop, 'cleanup') as cleanup:
            laptop.guard()
        cleanup.assert_called_once()

    def test_wrong_process_identity_is_never_signalled(self):
        with patch.object(laptop, 'identity', return_value=['42', 'other', 'boot']), \
                patch.object(laptop.os, 'kill') as kill:
            laptop.signal_process(['42', 'old', 'boot'])
        kill.assert_not_called()

    def test_remote_startup_exit_runs_cleanup_before_return(self):
        arguments = Mock(host='yme@pi', latency=20)
        result = subprocess.CompletedProcess([], 0, '{"ready":true}', '')
        guardian = Mock(stdin=io.StringIO())
        launcher = Mock()
        launcher.poll.return_value = 1
        initial = copy.deepcopy(self.initial)
        initial['sinks'].pop(3)
        with patch.object(laptop, 'local_check'), patch.object(laptop, 'snapshot', return_value=initial), \
                patch.object(laptop, 'run', return_value=result), \
                patch.object(laptop, 'service_active', return_value='active'), \
                patch.object(laptop.socket, 'getaddrinfo', return_value=[(2, 2, 17, '', ('127.0.0.1', 46000))]), \
                patch.object(laptop.subprocess, 'Popen', side_effect=[guardian, launcher]), \
                patch.object(laptop, 'cleanup') as cleanup:
            with self.assertRaisesRegex(RuntimeError, 'Pi launcher exited'):
                laptop.start(arguments)
        cleanup.assert_called_once()
        saved = json.loads(laptop.STATE.read_text())
        self.assertNotIn('sender_changed', saved)


class PiLifecycleTests(unittest.TestCase):
    def test_missing_packets_fail_even_when_nodes_are_running(self):
        output = receiver.Receiver.__new__(receiver.Receiver)
        output.period = 128
        output.missing_rtp_since = None
        nodes = [{'info': {'state': 'running', 'props': {'node.name': 'syren_hifiberry'}}},
                 {'info': {'state': 'running', 'props': {'node.name': 'syren_rtp_receive',
                                                      'rtp.receiving': False}}}]
        output.command = Mock(return_value=Mock(stdout=json.dumps(nodes)))
        with patch.object(receiver.Path, 'read_text', return_value='period_size: 128\nrate: 48000 (48000/1)\n'), \
                patch.object(receiver.time, 'monotonic', side_effect=[10, 17]):
            output.check_health(expect_rtp=True)
            output.check_health()
            with self.assertRaisesRegex(RuntimeError, 'packets stopped arriving'):
                output.check_health(expect_rtp=True)

    def test_packet_recovery_clears_timeout(self):
        output = receiver.Receiver.__new__(receiver.Receiver)
        output.period = 128
        output.missing_rtp_since = 1
        nodes = [{'info': {'state': 'running', 'props': {'node.name': 'syren_hifiberry'}}},
                 {'info': {'state': 'running', 'props': {'node.name': 'syren_rtp_receive',
                                                      'rtp.receiving': True}}}]
        output.command = Mock(return_value=Mock(stdout=json.dumps(nodes)))
        with patch.object(receiver.Path, 'read_text', return_value='period_size: 128\nrate: 48000 (48000/1)\n'):
            output.check_health(expect_rtp=True)
        self.assertTrue(output.receiving)
        self.assertIsNone(output.missing_rtp_since)

    def test_volume_increases_require_small_explicit_steps(self):
        output = receiver.Receiver.__new__(receiver.Receiver)
        output.volume = 10
        output.set_volume = Mock()
        output.adjust(20, False)
        output.set_volume.assert_called_once_with(20, False)
        with self.assertRaisesRegex(ValueError, '10 percentage points'):
            output.adjust(30, False)
        with self.assertRaises(ValueError):
            output.adjust(True, False)
        output.volume = 80
        output.adjust(0, True)
        output.set_volume.assert_called_with(0, True)

    def test_stop_failure_is_journaled_before_mutating_snapclient(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            account = receiver.pwd.getpwuid(receiver.os.getuid())
            lock_file = (directory / 'lock').open('w')
            with patch.object(receiver, 'ROOT_STATE', directory / 'state' / 'state.json'), \
                    patch.object(receiver, 'RUNTIME', directory / 'runtime'), \
                    patch.object(receiver, 'open', return_value=lock_file, create=True), \
                    patch.object(receiver, 'snap_state', return_value='active'), \
                    patch.object(receiver, 'run', side_effect=RuntimeError('stop failed')), \
                    patch.object(receiver.subprocess, 'Popen') as child:
                with self.assertRaisesRegex(RuntimeError, 'stop failed'):
                    receiver.supervise(Mock(user=account.pw_name, session='0' * 32, latency=20))
                state = json.loads(receiver.ROOT_STATE.read_text())
                self.assertTrue(state['snap_active'])
                self.assertTrue(state['snap_changed'])
                child.assert_not_called()

    def test_restore_only_starts_previously_active_snapclient(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(receiver, 'ROOT_STATE', Path(temporary) / 'state.json'), \
                patch.object(receiver, 'snap_state', side_effect=['inactive', 'active']), \
                patch.object(receiver, 'run') as execute:
            receiver.atomic_json(receiver.ROOT_STATE, {'snap_changed': True, 'snap_active': True})
            receiver.restore()
            receiver.restore()
            execute.assert_called_once_with(['systemctl', 'start', 'snapclient.service'], timeout=30)
            self.assertFalse(receiver.ROOT_STATE.exists())

    def test_previously_inactive_snapclient_stays_inactive(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(receiver, 'ROOT_STATE', Path(temporary) / 'state.json'), \
                patch.object(receiver, 'run') as execute:
            receiver.atomic_json(receiver.ROOT_STATE, {'snap_changed': False, 'snap_active': False})
            receiver.restore()
            execute.assert_not_called()

    def test_failed_snapclient_restore_retains_state(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(receiver, 'ROOT_STATE', Path(temporary) / 'state.json'), \
                patch.object(receiver, 'snap_state', return_value='inactive'), \
                patch.object(receiver, 'run', side_effect=RuntimeError('failed')):
            receiver.atomic_json(receiver.ROOT_STATE, {'snap_changed': True, 'snap_active': True})
            with self.assertRaises(RuntimeError):
                receiver.restore()
            self.assertTrue(receiver.ROOT_STATE.exists())

    def test_transient_unit_has_cleanup_even_if_supervisor_is_killed(self):
        arguments = Mock(session='0' * 32, latency=20)
        with patch.dict(receiver.os.environ, {'SUDO_USER': 'yme'}), \
                patch.object(receiver.pwd, 'getpwnam', return_value=Mock(pw_name='yme')), \
                patch.object(receiver.subprocess, 'call', return_value=0) as execute:
            receiver.launch(arguments)
        command = execute.call_args.args[0]
        self.assertIn('--property=KillMode=control-group', command)
        self.assertIn(f'--property=ExecStopPost={receiver.INSTALL}/pi.py restore', command)
        self.assertIn('--property=Restart=no', command)


if __name__ == '__main__':
    unittest.main()
