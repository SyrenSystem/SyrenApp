#!/usr/bin/env python3
"""Measure real Snapcast session inputs, mixing, mute, and warm handoffs."""

import json
import math
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid

DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DIRECTORY))
import session_graph
from smoke_shared import amplitude


def unused_port():
    with socket.socket() as connection:
        connection.bind(('127.0.0.1', 0))
        return connection.getsockname()[1]


def main():
    assert shutil.which('snapclient'), 'Install Snapclient 0.35 with the Pulse backend'
    before = subprocess.run(['pactl', 'get-default-sink'], capture_output=True).stdout if shutil.which('pactl') else None
    native_server = None
    remote = os.environ.get('SYREN_SIGNAL_HOST')
    host = remote or '127.0.0.1'
    physical_id = 'fixture-' + socket.gethostname()
    container = 'syren-session-signal-' + uuid.uuid4().hex
    ports = {name: int(os.environ.get('SYREN_SIGNAL_' + name.upper() + '_PORT', unused_port())) for name in ('control', 'audio', 'first', 'second')}
    running = threading.Event()
    running.set()
    with tempfile.TemporaryDirectory(prefix='syren-sessions-signal-') as temporary:
        directory = Path(temporary)
        configuration = directory / 'snapserver.conf'
        configuration.write_text(f'''[http]
enabled=false
[tcp]
bind_to_address=127.0.0.1
port={ports['control']}
[stream]
bind_to_address=127.0.0.1
port={ports['audio']}
source=tcp://127.0.0.1:{ports['first']}?name=first&mode=server&sampleformat=48000:16:2&codec=pcm
source=tcp://127.0.0.1:{ports['second']}?name=second&mode=server&sampleformat=48000:16:2&codec=pcm
buffer=200
[logging]
sink=stdout
filter=*:warning
''')
        if not remote and os.environ.get('SYREN_SIGNAL_NATIVE') == '1':
            native_server = subprocess.Popen(['snapserver', '--config', str(configuration),
                '--server.datadir=' + str(directory / 'state')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection((host, ports['control']), timeout=.1):
                        break
                except OSError:
                    assert time.monotonic() < deadline, 'Native Snapserver did not start'
                    time.sleep(.05)
        elif not remote:
            subprocess.run(['podman', 'run', '-d', '--rm', '--name', container, '--network', 'host', '--userns=keep-id',
                            '--user', f'{os.getuid()}:{os.getgid()}', '-v', f'{configuration}:/config:ro',
                            '--entrypoint', '/usr/bin/snapserver', os.environ.get('SYREN_AUDIO_IMAGE', 'syren-snapserver-check'),
                            '--config', '/config', '--server.datadir=/tmp/state'], check=True, stdout=subprocess.DEVNULL)
        (directory / 'templates').mkdir()
        template = (DIRECTORY / 'templates/session-output.conf.in').read_text()
        template = template.replace('api.alsa.pcm.sink', 'support.null-audio-sink')
        template = template.replace('audio.format = S32', 'audio.format = F32\n        node.driver = true')
        template = template.replace('mode = dsp monitor = false', 'mode = dsp monitor = true')
        template = template.replace('context.objects = [', '''context.objects = [
          { factory = spa-node-factory args = { factory.name = support.node.driver
              node.name = Dummy-Driver node.group = pipewire.dummy priority.driver = 10000 } }
        ''')
        (directory / 'templates/session-output.conf.in').write_text(template)
        shutil.copy(DIRECTORY / 'templates/pulse.conf', directory / 'templates')
        hardware = directory / 'hw_params'
        hardware.write_text('format: S32_LE\nchannels: 2\nrate: 48000 (48000/1)\nperiod_size: 128\nbuffer_size: 384\n')
        session_graph.INSTALL = directory
        graph = session_graph.SessionOutputGraph(directory / 'runtime', 'unused', hardware, physical_id, host, ports['audio'])
        recorder = None
        senders = []

        def request(method, parameters=None):
            with socket.create_connection((host, ports['control']), timeout=3) as connection:
                connection.sendall((json.dumps({'id': 1, 'jsonrpc': '2.0', 'method': method, 'params': parameters or {}}) + '\n').encode())
                reader = connection.makefile('r')
                while True:
                    response = json.loads(reader.readline())
                    if response.get('id') == 1:
                        assert 'error' not in response, response
                        return response['result']

        def transmit(name, frequency):
            packet = b''.join(struct.pack('<hh', *([int(3000 * math.sin(index * 2 * math.pi * frequency / 48000))] * 2)) for index in range(480))
            with socket.create_connection((host, ports[name]), timeout=3) as connection:
                scheduled = time.monotonic()
                while running.is_set():
                    connection.sendall(packet)
                    scheduled += .01
                    time.sleep(max(0, scheduled - time.monotonic()))

        try:
            graph.start()
            for name, frequency in (('first', 400), ('second', 1000)):
                graph.ensure_snapcast(name, {'id': name, 'endpoint': name})
                sender = threading.Thread(target=transmit, args=(name, frequency), daemon=True)
                sender.start()
                senders.append(sender)
            deadline = time.monotonic() + 8
            bound = set()
            settled_since = None
            while time.monotonic() < deadline:
                graph.repair_links()
                for name in ('first', 'second'):
                    graph.ensure_snapcast(name, {'id': name, 'endpoint': name})
                ready = {item['clientId'] for item in graph.status() if item['receiving']}
                status = request('Server.GetStatus')['server']
                for group in status['groups']:
                    for client in group['clients']:
                        for name in ('first', 'second'):
                            if client['id'] == session_graph.snapclient_identity(physical_id, name) and client['connected'] and client['id'] in ready:
                                if group['stream_id'] != name:
                                    request('Group.SetStream', {'id': group['id'], 'stream_id': name})
                                request('Client.SetVolume', {'id': client['id'], 'volume': {'percent': 100, 'muted': False}})
                                bound.add(name)
                graph.repair_links()
                if len(bound) == 2 and all(item['receiving'] for item in graph.status()):
                    settled_since = settled_since or time.monotonic()
                    if time.monotonic() - settled_since >= 1:
                        break
                else:
                    settled_since = None
                time.sleep(.1)
            assert len(bound) == 2 and all(item['receiving'] for item in graph.status()), graph.status()
            capture = directory / 'capture.raw'
            with capture.open('wb') as output:
                recorder = subprocess.Popen(['pw-cat', '--record', '--raw', '--rate', '48000', '--channels', '2', '--format', 's16',
                    '--target', '0', '-P', '{ node.name = syren_capture node.autoconnect = false adapter.auto-port-config = { mode = dsp position = preserve } }', '-'],
                    env=graph.environment, stdout=output, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 3
            while 'syren_capture:input_FL' not in graph.command('pw-link', '-i').stdout:
                assert time.monotonic() < deadline, 'Recorder ports are missing'
                time.sleep(.02)
            for channel in ('FL', 'FR'):
                graph.command('pw-link', f'syren_hifiberry:monitor_{channel}', f'syren_capture:input_{channel}')
            identities = [graph.process.pid, graph.pulse.pid] + [item['process'].pid for item in graph.inputs.values()]

            def sample():
                graph.repair_links()
                time.sleep(.2)
                offset = capture.stat().st_size
                time.sleep(.25)
                data = capture.read_bytes()[offset:]
                return struct.unpack('<' + 'h' * (len(data) // 2), data)[::2]

            evidence = []
            for selected in ('first', 'second') * int(os.environ.get('SYREN_SIGNAL_CYCLES', '12')):
                offset = capture.stat().st_size // 4 * 4
                started = time.monotonic()
                graph.apply({selected: .6})
                elapsed = time.monotonic() - started
                assert elapsed < .25, f'Warm session switch exceeded 250 ms: {elapsed}'
                samples = sample()
                levels = {frequency: amplitude(samples, frequency) for frequency in (400, 1000)}
                assert levels[400 if selected == 'first' else 1000] > 500, levels
                assert levels[1000 if selected == 'first' else 400] < 25, levels
                transition = capture.read_bytes()[offset:]
                transition_samples = struct.unpack('<' + 'h' * (len(transition) // 2), transition)[::2]
                silence = longest_silence = 0
                for value in transition_samples:
                    silence = silence + 1 if abs(value) <= 2 else 0
                    longest_silence = max(silence, longest_silence)
                assert longest_silence / 48000 < .25, 'Session handoff cut out for 250 ms'
                evidence.append({'selected': selected, 'control_ms': round(elapsed * 1000, 2),
                                 'silence_ms': round(longest_silence / 48, 2), 'levels': levels})
            graph.apply({'first': .5, 'second': .5})
            samples = sample()
            assert amplitude(samples, 400) > 500 and amplitude(samples, 1000) > 500, 'Sessions did not mix'
            assert identities == [graph.process.pid, graph.pulse.pid] + [item['process'].pid for item in graph.inputs.values()], 'A healthy process restarted'
            rtp_port = unused_port()
            graph.ensure_rtp('pc', {'id': 'rtp', 'endpoint': f'rtp://127.0.0.1@127.0.0.1:{rtp_port}'})

            def transmit_rtp():
                sequence = timestamp = 0
                scheduled = time.monotonic()
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
                    while running.is_set():
                        payload = b''.join(struct.pack('!hh', *([int(3000 * math.sin((timestamp + index) * 2 * math.pi * 1600 / 48000))] * 2)) for index in range(120))
                        connection.sendto(struct.pack('!BBHII', 128, 127, sequence % 65536, timestamp % (2 ** 32), 991) + payload, ('127.0.0.1', rtp_port))
                        sequence += 1
                        timestamp += 120
                        scheduled += .0025
                        time.sleep(max(0, scheduled - time.monotonic()))

            sender = threading.Thread(target=transmit_rtp, daemon=True)
            sender.start()
            senders.append(sender)
            deadline = time.monotonic() + 4
            while not graph.inputs['rtp']['receiving']:
                assert time.monotonic() < deadline, 'RTP input did not receive advancing audio'
                graph.repair_links()
                time.sleep(.05)
            graph.apply({'rtp': .5})
            samples = sample()
            assert amplitude(samples, 1600) > 500 and amplitude(samples, 400) < 25, 'RTP isolation failed'
            graph.apply({'first': .5, 'rtp': .5})
            samples = sample()
            assert amplitude(samples, 1600) > 500 and amplitude(samples, 400) > 500, 'Spotify and PC inputs did not mix'
            identities = [graph.process.pid, graph.pulse.pid] + [item['process'].pid for item in graph.inputs.values()]
            graph.apply({})
            assert max(map(abs, sample())) <= 2, 'Mute did not silence all inputs'
            assert identities == [graph.process.pid, graph.pulse.pid] + [item['process'].pid for item in graph.inputs.values()], 'A healthy process restarted'
            print(json.dumps({'real_snapclients': True, 'switches': evidence, 'mixed_tones': True,
                              'confirmed_mute': True, 'unchanged_processes': True, 'rtp_mixed_and_isolated': True}))
        except Exception:
            Path('/tmp/syren-session-signal-failure.log').write_text((directory / 'runtime/pipewire.log').read_text())
            Path('/tmp/syren-session-signal-failure.json').write_text(json.dumps(graph.objects()))
            print((directory / 'runtime/pipewire.log').read_text()[-1000:], file=sys.stderr)
            raise
        finally:
            running.clear()
            if recorder:
                recorder.terminate()
                recorder.wait(timeout=2)
            graph.stop()
            for sender in senders:
                sender.join(timeout=2)
            if native_server:
                native_server.terminate()
                native_server.wait(timeout=5)
            elif not remote:
                subprocess.run(['podman', 'stop', '--time', '2', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    assert before is None or before == subprocess.run(['pactl', 'get-default-sink'], capture_output=True).stdout, 'Test changed desktop audio'


if __name__ == '__main__':
    main()
