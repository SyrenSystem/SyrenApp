#!/usr/bin/env python3
"""Check desktop RTP signal flow without sending sound to speakers."""

import json
import math
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import uuid


DIRECTORY = Path(__file__).resolve().parents[1]


def main():
    original_default = subprocess.check_output(['pactl', 'get-default-sink'])
    node_name = 'syren_rtp_check_' + uuid.uuid4().hex
    processes = []
    reports = []
    with tempfile.TemporaryDirectory(prefix='syren-rtp-desktop-') as temporary:
        directory = Path(temporary)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            receiver.bind(('127.0.0.1', 0))
            receiver.settimeout(0.3)
            configuration = (DIRECTORY / 'templates/sender.conf.in').read_text()
            for before, after in [('@REMOTE@', 'pipewire-0'), ('@LOCAL_IP@', '127.0.0.1'),
                                  ('@PI_IP@', '127.0.0.1'), ('SyrenSystem_Live', node_name),
                                  ('SyrenSystem Live', 'Syren silent desktop check'),
                                  ('destination.port = 46000',
                                   'destination.port = ' + str(receiver.getsockname()[1]))]:
                configuration = configuration.replace(before, after)
            configuration_path = directory / 'sender.conf'
            configuration_path.write_text(configuration)
            samples = [0.01 * math.sin(2 * math.pi * 3000 * frame / 48000) for frame in range(48000)]
            audio_path = directory / 'signal.f32'
            audio_path.write_bytes(b''.join(struct.pack('<ff', sample, sample) for sample in samples) * 20)
            try:
                with (directory / 'sender.log').open('w') as output:
                    sender = subprocess.Popen(['pipewire', '-c', str(configuration_path)],
                                              stdout=output, stderr=output)
                processes.append(sender)
                deadline = time.monotonic() + 5
                while node_name not in subprocess.check_output(['pactl', 'list', 'short', 'sinks'], text=True):
                    if sender.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Desktop verification sink did not appear')
                    time.sleep(0.1)
                player = subprocess.Popen(['pw-cat', '--playback', '--raw', '--format', 'f32',
                    '--rate', '48000', '--channels', '2', '--target', node_name, '--volume', '1',
                    '-P', '{ state.restore-props = false state.restore-target = false }', '-'],
                    stdin=audio_path.open('rb'))
                processes.append(player)
                for stage in ['initial playback', 'after sink inspection', 'after source inspection']:
                    if stage == 'after sink inspection':
                        subprocess.run(['pactl', '--format=json', 'list', 'sinks'],
                                       stdout=subprocess.DEVNULL, check=True)
                    elif stage == 'after source inspection':
                        subprocess.run(['pactl', '--format=json', 'list', 'sources'],
                                       stdout=subprocess.DEVNULL, check=True)
                    deadline = time.monotonic() + 3
                    packets = nonzero_packets = peak = 0
                    while time.monotonic() < deadline:
                        try:
                            packet, address = receiver.recvfrom(4096)
                        except socket.timeout:
                            continue
                        assert len(packet) == 492 and packet[0] >> 6 == 2
                        assert packet[1] & 127 == 127
                        packet_peak = max(abs(sample) for sample in struct.unpack('!240h', packet[12:]))
                        peak = max(peak, packet_peak)
                        packets += 1
                        nonzero_packets += packet_peak > 0
                    threads = [thread for thread in Path(f'/proc/{sender.pid}/task').iterdir()
                               if (thread / 'comm').read_text().strip().startswith('data-loop')]
                    assert threads, 'Sender audio thread did not appear'
                    for thread in threads:
                        policy = os.sched_getscheduler(int(thread.name)) & ~os.SCHED_RESET_ON_FORK
                        assert policy in (os.SCHED_RR, os.SCHED_FIFO), 'Sender audio thread lacks realtime scheduling'
                        assert os.sched_getparam(int(thread.name)).sched_priority > 0
                    report = {'stage': stage, 'packets': packets,
                              'nonzero_packets': nonzero_packets, 'peak_s16': peak}
                    reports.append(report)
                    assert packets >= 600 and nonzero_packets >= 600 and peak >= 200, report
            except Exception:
                print((directory / 'sender.log').read_text()[-4000:])
                raise
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
    assert subprocess.check_output(['pactl', 'get-default-sink']) == original_default
    print(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()
