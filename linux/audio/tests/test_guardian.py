import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
import time
import unittest

from test_ingress import PacketFilter
from common import atomic_json, process_alive, receive, send


DIRECTORY = Path(__file__).resolve().parents[1]


class GuardianTests(unittest.TestCase):
    def test_cli_preserves_status_with_errors_and_rejects_failed_commands(self):
        for report, exit_code in [
            ({'version': 1, 'state': 'idle', 'error': 'Previous startup failed',
              'preferences': {'opt_in': True}}, 0),
            ({'version': 1, 'error': 'Invalid operation'}, 1),
        ]:
            with self.subTest(report=report), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                runtime = directory / 'syren-rtp-controller'
                runtime.mkdir()
                with socket.socket(socket.AF_UNIX) as listener:
                    listener.bind(str(runtime / 'control.sock'))
                    listener.listen(1)
                    listener.settimeout(5)

                    def respond():
                        connection, address = listener.accept()
                        with connection:
                            receive(connection)
                            send(connection, report)

                    worker = threading.Thread(target=respond, daemon=True)
                    worker.start()
                    result = subprocess.run(['python3', str(DIRECTORY / 'laptop.py'),
                        '{"version":1,"action":"status"}'],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(directory)),
                        capture_output=True, text=True, timeout=5)
                    worker.join(timeout=1)
                self.assertEqual(result.returncode, exit_code)
                self.assertEqual(json.loads(result.stdout), report)

    def test_controller_pipe_death_stops_owned_sender_and_reconciles(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary_directory = directory / 'bin'
            binary_directory.mkdir()
            executable = binary_directory / 'pipewire'
            executable.write_text('#!/usr/bin/python3\nimport time\ntime.sleep(30)\n')
            executable.chmod(0o755)
            state_root = directory / 'state/syrensystem/rtp'
            atomic_json(state_root / 'state.json', {'session': 'abc', 'routing': {}, 'remote_start_intended': False})
            environment = dict(os.environ, XDG_STATE_HOME=str(directory / 'state'),
                XDG_CONFIG_HOME=str(directory / 'configuration'), XDG_RUNTIME_DIR=str(directory / 'runtime'),
                PATH=str(binary_directory) + ':' + os.environ['PATH'])
            process = subprocess.Popen(['python3', str(DIRECTORY / 'laptop.py'), '_guard', 'abc'],
                env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                process.stdin.write(b'{"action":"sender"}\n')
                process.stdin.flush()
                self.assertTrue(select.select([process.stdout], [], [], 2)[0])
                self.assertTrue(json.loads(process.stdout.readline())['started'])
                identity = json.loads((state_root / 'state.json').read_text())['sender_process']
                self.assertTrue(process_alive(identity))
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0, process.stderr.read().decode())
                self.assertFalse(process_alive(identity))
                self.assertFalse((state_root / 'state.json').exists())
                self.assertTrue((state_root / 'last-state.json').exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
                process.stdout.close()
                process.stderr.close()

    def test_json_wrapper_starts_idle_and_drain_exits_controller(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            environment = dict(os.environ, XDG_STATE_HOME=str(directory / 'state'),
                XDG_CONFIG_HOME=str(directory / 'configuration'), XDG_RUNTIME_DIR=str(directory / 'runtime'))
            executable = DIRECTORY.parent / 'packaging/syren-audio-control'
            result = subprocess.run([str(executable), 'rtp', '{"version":1,"action":"status"}'],
                                    env=environment, check=True, capture_output=True, text=True, timeout=5)
            self.assertEqual(json.loads(result.stdout)['state'], 'idle')
            for attempt in range(10):
                result = subprocess.run([str(executable), 'rtp', '{"version":1,"action":"drain"}'],
                                        env=environment, check=False, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)['state'], 'idle')
            socket_path = directory / 'runtime/syren-rtp-controller/control.sock'
            expires = time.monotonic() + 2
            while socket_path.exists() and time.monotonic() < expires:
                time.sleep(0.05)
            self.assertFalse(socket_path.exists())


if __name__ == '__main__':
    unittest.main()
