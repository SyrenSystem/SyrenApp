"""Check the three desktop devices with native capture and real time scheduling."""

import json
import math
import os
from pathlib import Path
import queue
import resource
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

from smoke_shared import amplitude


def check_desktop_outputs(environment, pulse, log, directory, wait, group_termination=False):
    names = {'auto': 'SyrenSystem', 'stable': 'SyrenSystem_stable', 'fast': 'SyrenSystem_fast'}
    frequency = 1000
    listeners = {}
    datagrams = {}
    received = {name: bytearray() for name in ('auto-tcp', 'auto-rtp')}
    traffic_classes = set()
    receive_times = []
    stopping = threading.Event()
    players = []
    sender = None
    statuses = queue.Queue()
    transports = []

    def read_tcp(mode, listener):
        listener.settimeout(5)
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(.1)
            while not stopping.is_set():
                try:
                    data = connection.recv(4096)
                    if not data:
                        break
                    received[mode + '-tcp'].extend(data)
                except socket.timeout:
                    pass

    def read_rtp(mode, connection):
        connection.settimeout(.1)
        while not stopping.is_set():
            try:
                packet, ancillary, _, _ = connection.recvmsg(2048, 128)
                traffic_classes.update(data[0] for level, kind, data in ancillary
                                       if level == socket.IPPROTO_IP and kind == socket.IP_TOS)
                for level, kind, data in ancillary:
                    if level == socket.SOL_SOCKET and kind == 35:
                        seconds, nanoseconds = struct.unpack('ll', data)
                        receive_times.append(seconds * 1000000000 + nanoseconds)
                assert len(packet) == 492 and packet[:2] == b'\x80\x7f', 'Invalid desktop RTP packet'
                samples = struct.unpack('!240h', packet[12:])
                received[mode + '-rtp'].extend(struct.pack('<240h', *samples))
            except socket.timeout:
                pass

    try:
        for mode in ('auto',):
            listener = socket.socket()
            listeners[mode] = listener
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            transports.append({'id': mode + '-tcp', 'kind': 'snapcast',
                               'tcpPort': listener.getsockname()[1]})
            threading.Thread(target=read_tcp, args=(mode, listener), daemon=True).start()
        for mode in ('auto',):
            connection = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            connection.setsockopt(socket.IPPROTO_IP, socket.IP_RECVTOS, 1)
            connection.setsockopt(socket.SOL_SOCKET, 35, 1)
            connection.bind(('127.0.0.1', 0))
            datagrams[mode] = connection
            transports.append({'id': mode + '-rtp', 'kind': 'rtp',
                'endpoint': f'rtp://127.0.0.1@127.0.0.1:{connection.getsockname()[1]}'})
            threading.Thread(target=read_rtp, args=(mode, connection), daemon=True).start()
        command = [sys.executable, str(Path(__file__).resolve().parents[1] / 'profile_pc_sender.py')]
        launch_environment = environment
        if resource.getrlimit(resource.RLIMIT_RTPRIO)[0] < 86 and os.geteuid() != 0:
            command = ['systemd-run', '--user', '--pipe', '--wait', '--collect', '--quiet',
                       '--property=LimitRTPRIO=86', '--property=ExitType=cgroup',
                       *['--setenv=' + name + '=' + value for name, value in environment.items()
                         if name in ('XDG_RUNTIME_DIR', 'PIPEWIRE_RUNTIME_DIR', 'PULSE_SERVER',
                                     'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'DBUS_SESSION_BUS_ADDRESS')],
                       '--', *command]
            launch_environment = dict(environment, DBUS_SESSION_BUS_ADDRESS=f'unix:path=/run/user/{os.getuid()}/bus')
        sender = subprocess.Popen(command, env=launch_environment, stdin=subprocess.PIPE, start_new_session=True,
                                  stdout=subprocess.PIPE, stderr=log, text=True)

        def read_status():
            for line in sender.stdout:
                statuses.put(json.loads(line))

        threading.Thread(target=read_status, daemon=True).start()
        sender.stdin.write(json.dumps({'sessionId': uuid.uuid4().hex, 'host': '127.0.0.1',
            'transports': transports, 'desktopOutputs': True, 'mode': 'auto'}) + '\n')
        sender.stdin.flush()
        initial = statuses.get(timeout=8)
        assert initial['mode'] == 'auto' and initial['realtimePriority'] == 86, initial
        assert pulse('get-default-sink') == names['auto']
        sinks = json.loads(pulse('-f', 'json', 'list', 'sinks'))
        assert set(names.values()) <= {sink['name'] for sink in sinks}
        identities = initial['senderPid'], initial['capturePids']
        for process_id in initial['capturePids']:
            assert os.sched_getscheduler(process_id) == os.SCHED_FIFO
            assert os.sched_getparam(process_id).sched_priority == 86
        audio_threads = [int(task.name) for task in Path(f'/proc/{initial["senderPid"]}/task').iterdir()
                         if os.sched_getscheduler(int(task.name)) == os.SCHED_FIFO]
        assert len(audio_threads) == 2, audio_threads
        assert all(os.sched_getparam(thread_id).sched_priority == 86 for thread_id in audio_threads)
        tone = b''.join(struct.pack('<hh', *([int(3000 * math.sin(index * 2 * math.pi * frequency / 48000))] * 2))
                        for index in range(48000))
        source = directory / 'programme.raw'
        source.write_bytes(tone * 30)
        players.append(subprocess.Popen(['paplay', '--raw', '--rate=48000', '--channels=2',
            '--format=s16le', '--latency-msec=20', '--device=' + names['auto'], str(source)],
            env=environment, stdout=log, stderr=log))
        sender.stdin.write('{}\n')
        sender.stdin.flush()
        wait(lambda: all(len(data) > 192000 for data in received.values()))
        assert traffic_classes == {184}, ('RTP needs the voice traffic class', traffic_classes)
        packet_gaps = sorted((later - earlier) / 1000000 for earlier, later in zip(receive_times, receive_times[1:]))
        assert len(packet_gaps) >= 300, 'Missing RTP arrival timestamps'
        packet_gap_percentile = packet_gaps[int(len(packet_gaps) * .95)]
        assert packet_gap_percentile < 5, ('Capture bursts exceed the 5 ms receiver target', packet_gap_percentile)
        time.sleep(.5)
        for lane, data in received.items():
            samples = struct.unpack('<48000h', bytes(data[-96000:]))[::2]
            assert amplitude(samples, frequency) > 2000, (lane, 'missing programme')
        with statuses.mutex:
            statuses.queue.clear()
        for index in range(1 if group_termination else 20):
            offsets = {lane: len(data) for lane, data in received.items()}
            mode = ('stable', 'fast', 'auto')[index % 3]
            if index % 2:
                pulse('set-default-sink', names[mode])
            else:
                sender.stdin.write(json.dumps({'mode': mode}) + '\n')
                sender.stdin.flush()
            deadline = time.monotonic() + 1
            while True:
                status = statuses.get(timeout=max(.001, deadline - time.monotonic()))
                if status['mode'] == mode and status['activeModes'] == [mode]:
                    break
                assert time.monotonic() < deadline, 'Desktop mode did not change live'
            assert (status['senderPid'], status['capturePids']) == identities, 'Mode change restarted capture'
            sender.stdin.write('{}\n')
            sender.stdin.flush()
            time.sleep(.3)
            for lane, data in received.items():
                transition = bytes(data[offsets[lane]:])
                transition = transition[:len(transition) // 4 * 4]
                samples = struct.unpack('<' + 'h' * (len(transition) // 2), transition)[::2]
                assert amplitude(samples[-12000:], frequency) > 2000, (mode, lane, 'programme not warm')
                silence = longest_silence = 0
                for value in samples:
                    silence = silence + 1 if abs(value) <= 2 else 0
                    longest_silence = max(silence, longest_silence)
                assert longest_silence / 48000 < .25, (mode, lane, 'mode change cut out for 250 ms')
        if group_termination:
            os.killpg(os.getpgid(initial['senderPid']), signal.SIGTERM)
            sender.wait(timeout=5)
            sender.stdin.close()
        else:
            sender.stdin.close()
            assert sender.wait(timeout=5) == 0, 'Desktop capture failed during shutdown'
        wait(lambda: pulse('get-default-sink') == 'fixture_previous')
        wait(lambda: not set(names.values()) & {sink['name'] for sink in json.loads(pulse('-f', 'json', 'list', 'sinks'))})
        print(json.dumps({'desktop_outputs': list(names.values()), 'snapcast_and_rtp_always_warm': True,
            'live_mode_changes': 1 if group_termination else 20, 'capture_priority': 86, 'audio_thread_priority': 86,
            'group_termination_restored': group_termination,
            'rtp_traffic_class': 184,
            'packet_gap_p95_msec': packet_gap_percentile,
            'capture_processes_preserved': True, 'routing_restored': True}))
    finally:
        stopping.set()
        for player in players:
            if player.poll() is None:
                player.terminate()
            player.wait(timeout=3)
        if sender is not None and sender.poll() is None:
            sender.terminate()
            sender.wait(timeout=5)
        for connection in [*listeners.values(), *datagrams.values()]:
            connection.close()
