#!/usr/bin/env python3
"""Measure source isolation using synthetic audio and a private virtual output."""

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

DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DIRECTORY))
import graph
import shared_graph
from ingress import Ingress, PacketFilter


def amplitude(samples, frequency):
    count = len(samples)
    assert count > 2000, 'Recorder did not produce enough samples'
    real = sum(value * math.cos(index * 2 * math.pi * frequency / 48000) for index, value in enumerate(samples))
    imaginary = sum(value * math.sin(index * 2 * math.pi * frequency / 48000) for index, value in enumerate(samples))
    return 2 * math.hypot(real, imaginary) / count


def main():
    before = subprocess.check_output(['pactl', 'get-default-sink'])
    with tempfile.TemporaryDirectory(prefix='syren-shared-smoke-') as temporary:
        directory = Path(temporary)
        (directory / 'templates').mkdir()
        configuration = (DIRECTORY / 'templates/shared-receiver.conf.in').read_text()
        configuration = configuration.replace('api.alsa.pcm.sink', 'support.null-audio-sink')
        configuration = configuration.replace('audio.format = S32', 'audio.format = F32\n        node.driver = true')
        configuration = configuration.replace('mode = dsp monitor = false', 'mode = dsp monitor = true')
        configuration = configuration.replace('context.objects = [', '''context.objects = [
          { factory = spa-node-factory args = { factory.name = support.node.driver
              node.name = Dummy-Driver node.group = pipewire.dummy priority.driver = 10000 } }
        ''')
        (directory / 'templates/shared-receiver.conf.in').write_text(configuration)
        shutil.copy(DIRECTORY / 'templates/pulse.conf', directory / 'templates')
        hardware = directory / 'hw_params'
        hardware.write_text('format: S32_LE\nchannels: 2\nrate: 48000 (48000/1)\nperiod_size: 128\nbuffer_size: 384\n')
        tone = b''.join(struct.pack('<hh', *([int(2000 * math.sin(index * 2 * math.pi * 400 / 48000))] * 2))
                        for index in range(48000))
        (directory / 'snapcast.raw').write_bytes(tone * 20)
        import shlex
        frontend = directory / 'snapclient'
        frontend.write_text('#!/bin/sh\nexec paplay --raw --rate=48000 --channels=2 --format=s16le --device=syren_snapcast_gain ' + shlex.quote(str(directory / 'snapcast.raw')) + '\n')
        frontend.chmod(0o755)
        graph.INSTALL = shared_graph.INSTALL = directory
        ingress = Ingress('127.0.0.1', PacketFilter('127.0.0.1', time.monotonic() + 60))
        port = ingress.prepare()
        receiver = shared_graph.SharedAudioGraph(directory / 'runtime', 20, 'unused', hardware, port,
                                                  snapcast={'host': '127.0.0.1', 'port': 1704, 'id': 'fixture'})
        receiver.environment['PATH'] = str(directory) + os.pathsep + os.environ['PATH']
        recorder = None
        running = threading.Event()
        running.set()
        frequency = [1000]
        sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

        def transmit():
            sequence = 0
            timestamp = 0
            scheduled = time.monotonic()
            while running.is_set():
                payload = b''.join(struct.pack('!hh', *([int(3000 * math.sin((timestamp + index) * 2 * math.pi * frequency[0] / 48000))] * 2)) for index in range(120))
                sender.sendto(struct.pack('!BBHII', 128, 127, sequence % 65536, timestamp % (2 ** 32), 991) + payload, ('127.0.0.1', 46000))
                sequence += 1
                timestamp += 120
                scheduled += .0025
                time.sleep(max(0, scheduled - time.monotonic()))

        try:
            receiver.start()
            ingress.open()
            threading.Thread(target=ingress.run, daemon=True).start()
            transmission = threading.Thread(target=transmit, daemon=True)
            transmission.start()
            capture = directory / 'capture.raw'
            with capture.open('wb') as output:
                recorder = subprocess.Popen(['pw-cat', '--record', '--raw', '--rate', '48000', '--channels', '2',
                    '--format', 's16', '--target', '0', '-P', '{ node.name = syren_capture node.autoconnect = false adapter.auto-port-config = { mode = dsp position = preserve } }', '-'],
                    env=receiver.environment, stdout=output, stderr=subprocess.DEVNULL)
            expires = time.monotonic() + 4
            while time.monotonic() < expires:
                try:
                    receiver.check_health()
                    if receiver.snapcast_node and 'syren_capture:input_FL' in receiver.command('pw-link', '-i').stdout:
                        break
                except RuntimeError:
                    pass
                time.sleep(.1)
            assert receiver.snapcast_node, 'Pulse playback ports did not connect'
            for channel in ['FL', 'FR']:
                receiver.command('pw-link', f'syren_hifiberry:monitor_{channel}', f'syren_capture:input_{channel}')
            identities = [receiver.process.pid] + [process.pid for process in receiver.children]

            def sample():
                time.sleep(.2)
                offset = capture.stat().st_size
                time.sleep(.25)
                data = capture.read_bytes()[offset:]
                return struct.unpack('<' + 'h' * (len(data) // 2), data)[::2]

            evidence = []
            for selected in ['snapcast', 'rtp', 'snapcast']:
                if selected == 'snapcast':
                    receiver.standby()
                else:
                    receiver.set_volume(40, False)
                samples = sample()
                levels = {frequency: round(amplitude(samples, frequency), 2) for frequency in [400, 1000]}
                assert levels[400 if selected == 'snapcast' else 1000] > 100, levels
                assert levels[1000 if selected == 'snapcast' else 400] < 25, levels
                evidence.append({'selected': selected, 'amplitudes': levels})
            frequency[0] = 1600
            time.sleep(.5)
            receiver.set_volume(40, False)
            samples = sample()
            assert amplitude(samples, 1600) > 100 and amplitude(samples, 1000) < 25
            receiver.mute_all(40)
            assert max(map(abs, sample())) <= 2, 'Mute did not silence both branches'
            receiver.check_health()
            assert identities == [receiver.process.pid] + [process.pid for process in receiver.children]
            assert ingress.filter.accepted > 1000
            print(json.dumps({'source_isolation': evidence, 'same_processes': True,
                              'old_audio_discarded': True, 'mute_confirmed_silent': True,
                              'accepted_packets': ingress.filter.accepted}))
        finally:
            running.clear()
            if 'transmission' in locals():
                transmission.join(timeout=2)
            sender.close()
            ingress.running = False
            ingress.close()
            if recorder:
                recorder.terminate()
                recorder.wait(timeout=3)
            receiver.stop()
    assert subprocess.check_output(['pactl', 'get-default-sink']) == before


if __name__ == '__main__':
    main()
