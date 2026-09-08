import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

from test_ingress import PacketFilter
from common import process_alive, process_identity


DIRECTORY = Path(__file__).resolve().parents[2] / 'packaging'


class SenderTests(unittest.TestCase):
    def test_restore_startup_skips_routes_and_termination_stops_children(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary_directory = directory / 'usr/bin'
            library_directory = directory / 'usr/lib/syrensystem'
            runtime = directory / 'runtime'
            for path in (binary_directory, library_directory, runtime):
                path.mkdir(parents=True)
            sender_path = library_directory / 'syren-laptop-audio-sender'
            shutil.copy(DIRECTORY / 'syren-laptop-audio-sender', sender_path)
            control = binary_directory / 'syren-audio-control'
            control.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIXTURE_COMMANDS"\nif [ "$1" = ensure-sink ]; then echo present; fi\n')
            recorder = binary_directory / 'pw-record'
            recorder.write_text('#!/usr/bin/python3\nimport sys\nimport time\nwhile True:\n    sys.stdout.buffer.write(bytes(480))\n    sys.stdout.flush()\n    time.sleep(0.02)\n')
            network = binary_directory / 'nc'
            network.write_text('#!/usr/bin/python3\nimport sys\nif "-h" in sys.argv:\n    print("-N")\nelse:\n    while sys.stdin.buffer.read(480):\n        pass\n')
            for path in (control, recorder, network):
                path.chmod(0o755)
            marker = runtime / 'syren-sender-restore-once'
            marker.write_text('{"session":"test"}')
            commands = directory / 'commands'
            environment = dict(os.environ, PATH=str(binary_directory) + ':' + os.environ['PATH'],
                               XDG_RUNTIME_DIR=str(runtime), FIXTURE_COMMANDS=str(commands))
            process = subprocess.Popen([str(sender_path)], env=environment, start_new_session=True,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                expires = time.monotonic() + 2
                children = []
                while time.monotonic() < expires:
                    children = Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split()
                    if len(children) >= 2 and not marker.exists():
                        break
                    time.sleep(0.02)
                identities = [process_identity(child) for child in children]
                self.assertFalse(marker.exists())
                self.assertNotIn('apply', commands.read_text())
                started = time.monotonic()
                process.terminate()
                self.assertEqual(process.wait(timeout=1), 0)
                self.assertLess(time.monotonic() - started, 1)
                time.sleep(0.05)
                self.assertFalse(any(process_alive(identity) for identity in identities))
                self.assertFalse(list(runtime.glob('*.fifo')))
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, 9)
                    process.wait(timeout=1)
                process.stderr.close()

    def test_restore_startup_still_reapplies_routes_after_the_sink_is_recreated(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary_directory = directory / 'usr/bin'
            library_directory = directory / 'usr/lib/syrensystem'
            runtime = directory / 'runtime'
            for path in (binary_directory, library_directory, runtime):
                path.mkdir(parents=True)
            sender_path = library_directory / 'syren-laptop-audio-sender'
            shutil.copy(DIRECTORY / 'syren-laptop-audio-sender', sender_path)
            control = binary_directory / 'syren-audio-control'
            # The sink is present at restore time and has to be recreated on every later pass.
            control.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIXTURE_COMMANDS"\n'
                               'if [ "$1" = ensure-sink ]; then\n'
                               '  if [ "$(grep -c ensure-sink "$FIXTURE_COMMANDS")" = 1 ]; then echo present; else echo created; fi\n'
                               'fi\n')
            recorder = binary_directory / 'pw-record'
            recorder.write_text('#!/usr/bin/python3\nimport time\ntime.sleep(5)\n')
            network = binary_directory / 'nc'
            network.write_text('#!/usr/bin/python3\nimport sys\nif "-h" in sys.argv:\n    print("-N")\n')
            for path in (control, recorder, network):
                path.chmod(0o755)
            marker = runtime / 'syren-sender-restore-once'
            marker.write_text('{"session":"test"}')
            commands = directory / 'commands'
            environment = dict(os.environ, PATH=str(binary_directory) + ':' + os.environ['PATH'],
                               XDG_RUNTIME_DIR=str(runtime), FIXTURE_COMMANDS=str(commands))
            process = subprocess.Popen([str(sender_path)], env=environment, start_new_session=True,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                expires = time.monotonic() + 4
                while time.monotonic() < expires:
                    if commands.exists() and 'apply' in commands.read_text():
                        break
                    time.sleep(0.05)
                recorded = commands.read_text().splitlines()
                self.assertEqual(recorded[:3], ['ensure-sink', 'ensure-sink', 'apply'])
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, 9)
                    process.wait(timeout=1)
                process.stderr.close()


if __name__ == '__main__':
    unittest.main()
