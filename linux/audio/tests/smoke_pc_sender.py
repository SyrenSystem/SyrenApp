#!/usr/bin/env python3
"""Check desktop capture and route recovery in a private Pulse server."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import uuid

DIRECTORY = Path(__file__).resolve().parents[1]


def wait(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, 'PC sender did not reach the required state'
        time.sleep(.02)


def main():
    original = subprocess.check_output(['pactl', 'get-default-sink'])
    with tempfile.TemporaryDirectory(prefix='syren-pc-sender-') as temporary:
        directory = Path(temporary)
        environment = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
                           PULSE_SERVER='unix:' + temporary + '/pulse/native',
                           XDG_CONFIG_HOME=temporary + '/config', XDG_STATE_HOME=temporary + '/state',
                           DBUS_SESSION_BUS_ADDRESS='unix:path=' + temporary + '/no-session-bus')
        environment.pop('PULSE_RUNTIME_PATH', None)
        environment.pop('PIPEWIRE_CONFIG_DIR', None)
        environment.pop('PIPEWIRE_REMOTE', None)
        configuration = Path('/usr/share/pipewire/pipewire.conf').read_text()
        (directory / 'pipewire.conf').write_text(configuration)
        log = (directory / 'audio.log').open('w')
        pipewire = subprocess.Popen(['pipewire', '-c', str(directory / 'pipewire.conf')], env=environment, stdout=log, stderr=log)
        pulse_server = subprocess.Popen(['pipewire-pulse'], env=environment, stdout=log, stderr=log)
        policy_configuration = Path('/usr/share/wireplumber/wireplumber.conf').read_text()
        for feature in ('hardware.audio', 'hardware.bluetooth', 'hardware.video-capture'):
            policy_configuration = policy_configuration.replace(feature + ' = required', feature + ' = disabled')
        (directory / 'wireplumber.conf').write_text(policy_configuration)
        policy = subprocess.Popen(['wireplumber', '-c', str(directory / 'wireplumber.conf')], env=environment, stdout=log, stderr=log)
        processes = []

        def pulse(*arguments):
            return subprocess.check_output(['pactl', *arguments], env=environment, text=True, stderr=subprocess.DEVNULL).strip()

        try:
            wait(lambda: subprocess.run(['pactl', 'info'], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0)
            pulse('load-module', 'module-null-sink', 'sink_name=fixture_previous')
            pulse('set-default-sink', 'fixture_previous')
            wait(lambda: pulse('get-default-sink') == 'fixture_previous')
            for mode in ('owner-exit', 'owner-timeout', 'capture-killed'):
                with socket.socket() as listener:
                    listener.bind(('127.0.0.1', 0))
                    listener.listen()
                    listener.settimeout(5)
                    identity = uuid.uuid4().hex
                    sender = subprocess.Popen([sys.executable, str(DIRECTORY / 'profile_pc_sender.py')],
                        env=environment, stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
                    processes.append(sender)
                    sender.stdin.write(json.dumps({'sessionId': identity, 'host': '127.0.0.1',
                        'transports': [{'kind': 'snapcast', 'tcpPort': listener.getsockname()[1]}]}) + '\n')
                    sender.stdin.flush()
                    wait(lambda: pulse('get-default-sink') == 'SyrenSession_' + identity)
                    connection, _ = listener.accept()
                    connection.settimeout(3)
                    with connection:
                        samples = connection.recv(4096)
                        assert samples, 'Capture did not advance during silence'
                        for index in range(5):
                            sender.stdin.write('{}\n')
                            sender.stdin.flush()
                            time.sleep(.1)
                        assert sender.poll() is None, 'Silent capture ended while its app was alive'
                        if mode == 'owner-exit':
                            sender.stdin.close()
                        elif mode == 'capture-killed':
                            sender.kill()
                        sender.wait(timeout=5)
                    if not sender.stdin.closed:
                        sender.stdin.close()
                    wait(lambda: pulse('get-default-sink') == 'fixture_previous')
                    wait(lambda: not any(sink['name'] == 'SyrenSession_' + identity for sink in json.loads(pulse('-f', 'json', 'list', 'sinks'))))
            print(json.dumps({'capture_advances_during_silence': True, 'owner_exit_restores_routing': True,
                              'owner_timeout_restores_routing': True, 'capture_kill_restores_routing': True}))
        except Exception:
            print('Default:', pulse('get-default-sink'), 'Sinks:', pulse('list', 'short', 'sinks'), file=sys.stderr)
            print((directory / 'audio.log').read_text()[-1500:], file=sys.stderr)
            raise
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            for process in (policy, pulse_server, pipewire):
                process.terminate()
                process.wait(timeout=5)
            log.close()
    assert original == subprocess.check_output(['pactl', 'get-default-sink']), 'PC test changed desktop routing'


if __name__ == '__main__':
    main()
