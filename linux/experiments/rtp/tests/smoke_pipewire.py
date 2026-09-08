#!/usr/bin/env python3
"""Check native modules in an isolated graph with silent virtual devices."""

import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time


DIRECTORY = Path(__file__).resolve().parents[1]


def main():
    before = subprocess.check_output(['pactl', 'get-default-sink'])
    with tempfile.TemporaryDirectory(prefix='syren-rtp-smoke-') as temporary:
        directory = Path(temporary)
        shutil.copy('/usr/share/pipewire/client.conf', directory)
        configuration = (DIRECTORY / 'templates/receiver.conf.in').read_text()
        configuration = configuration.replace('@LATENCY@', '20').replace('@PERIOD@', '128')
        configuration = configuration.replace('api.alsa.pcm.sink', 'support.null-audio-sink')
        configuration = configuration.replace('audio.format = S32', 'audio.format = F32\n        node.driver = true')
        configuration = configuration.replace('context.objects = [', '''context.objects = [
            { factory = spa-node-factory args = {
                factory.name = support.node.driver
                node.name = Dummy-Driver
                node.group = pipewire.dummy
                priority.driver = 10000
            } }
        ''')
        (directory / 'receiver.conf').write_text(configuration)
        sender_configuration = (DIRECTORY / 'templates/sender.conf.in').read_text()
        sender_configuration = sender_configuration.replace('@REMOTE@', 'syren-rtp')
        sender_configuration = sender_configuration.replace('@LOCAL_IP@', '127.0.0.1').replace('@PI_IP@', '127.0.0.1')
        sender_configuration = sender_configuration.replace('destination.port = 46000', 'destination.port = 46001')
        sender_configuration = sender_configuration.replace('stream.props = {',
            'stream.props = { adapter.auto-port-config = { mode = dsp position = preserve }')
        (directory / 'sender.conf').write_text(sender_configuration)
        environment = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
                           PIPEWIRE_REMOTE='syren-rtp', PIPEWIRE_CONFIG_DIR=temporary)
        processes = []
        def execute(*arguments):
            return subprocess.check_output(arguments, env=environment, text=True, stderr=subprocess.PIPE, timeout=4)
        def start(filename):
            with (directory / (filename + '.log')).open('a') as output:
                process = subprocess.Popen(['pipewire', '-c', str(directory / filename)],
                                           env=environment, stdout=output, stderr=output)
            processes.append(process)
            return process
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as proxy:
                proxy.bind(('127.0.0.1', 46001))
                proxy.settimeout(3)
                start('receiver.conf')
                time.sleep(0.4)
                for channel in ['FL', 'FR']:
                    execute('pw-link', f'syren_rtp_receive:receive_{channel}', f'syren_hifiberry:playback_{channel}')
                silent_source = subprocess.Popen(['pw-cat', '--playback', '--raw', '--format', 's16', '--rate', '48000', '--channels', '2', '--target', '0', '-P', '{ node.name = syren_silent_test node.autoconnect = false adapter.auto-port-config = { mode = dsp position = preserve } }', '-'], stdin=open('/dev/zero'), env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                processes.append(silent_source)
                packet_counts = []
                for attempt in range(2):
                    sender = start('sender.conf')
                    time.sleep(0.3)
                    for channel in ['FL', 'FR']:
                        execute('pw-link', f'syren_silent_test:output_{channel}', f'SyrenSystem_Live:send_{channel}')
                    warmup_deadline = time.monotonic() + 0.2
                    while time.monotonic() < warmup_deadline:
                        packet, address = proxy.recvfrom(2048)
                        proxy.sendto(packet, ('127.0.0.1', 46000))
                    previous_sequence = None
                    previous_timestamp = None
                    packet_count = 0
                    deadline = time.monotonic() + 1
                    while time.monotonic() < deadline:
                        packet, address = proxy.recvfrom(2048)
                        version, payload, sequence, timestamp, stream_id = struct.unpack('!BBHII', packet[:12])
                        assert version >> 6 == 2 and payload & 127 == 127
                        assert len(packet) == 492, len(packet)
                        assert not any(packet[12:]), 'Test source must remain silent'
                        if previous_sequence is not None:
                            assert (sequence - previous_sequence) % 65536 == 1
                            assert (timestamp - previous_timestamp) % (2 ** 32) == 120
                        previous_sequence, previous_timestamp = sequence, timestamp
                        proxy.sendto(packet, ('127.0.0.1', 46000))
                        packet_count += 1
                    assert packet_count >= 100, packet_count
                    packet_counts.append(packet_count)
                    objects = json.loads(execute('pw-dump'))
                    output = next(item for item in objects if item.get('info', {}).get('props', {}).get('node.name') == 'syren_hifiberry')
                    assert output['info']['state'] == 'running'
                    properties = output['info']['params']['Props'][0]
                    assert properties['mute'] is True
                    assert all(abs(volume - 0.1) < 0.00001 for volume in properties['channelVolumes'])
                    sender.terminate()
                    sender.wait(timeout=5)
                    time.sleep(0.2)
                    proxy.settimeout(0.01)
                    try:
                        while proxy.recvfrom(2048):
                            pass
                    except socket.timeout:
                        pass
                    proxy.settimeout(3)
                print(execute('pw-top', '-b', '-n', '2'))
                print(json.dumps({'packet_counts': packet_counts, 'pcm_frames_per_packet': 120,
                                  'packet_bytes': 492, 'initial_mute': True,
                                  'initial_software_volume': 10, 'sender_restart': 'passed'}))
        except Exception:
            for path in directory.glob('*.log'):
                print(path.name, path.read_text()[-3000:])
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
    assert subprocess.check_output(['pactl', 'get-default-sink']) == before


if __name__ == '__main__':
    main()
