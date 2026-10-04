#!/usr/bin/python3
"""Keep desktop capture alive only while its owning app is responding."""

import json
import fcntl
import os
from pathlib import Path
import queue
import resource
import selectors
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse


# The capture and send path runs just below the 88 PipeWire uses, when this user is allowed real time.
PRIORITY = 86
RTP_TRAFFIC_CLASS = 46 << 2
RTP_SOCKET_PRIORITY = 6


def create_rtp_socket():
    connection = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        connection.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, RTP_TRAFFIC_CLASS)
        connection.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, RTP_SOCKET_PRIORITY)
    except OSError:
        connection.close()
        raise
    return connection


def realtime_priority():
    limit = resource.getrlimit(resource.RLIMIT_RTPRIO)[0]
    if os.geteuid() == 0 or limit == resource.RLIM_INFINITY:
        return PRIORITY
    return min(PRIORITY, limit) if limit > 0 else None


def make_realtime(required=False):
    priority = realtime_priority()
    if required and priority != PRIORITY:
        raise RuntimeError('PC capture needs the user service real time limit of 86 or higher')
    if priority:
        try:
            # On Linux this changes only the calling thread.
            os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(priority))
        except OSError:
            if required:
                raise


def pulse(*arguments):
    return subprocess.check_output(['pactl', *arguments], text=True, timeout=2).strip()


def legacy_main(configuration):
    identity = configuration['sessionId']
    if len(identity) != 32 or any(character not in '0123456789abcdef' for character in identity):
        raise ValueError('Invalid session identity')
    sink = 'SyrenSession_' + identity
    previous = pulse('get-default-sink')
    module = pulse('load-module', 'module-null-sink', 'sink_name=' + sink,
                   'rate=48000', 'channels=2', 'format=s16le', 'sink_properties=device.description=SyrenSystem_PC')
    guardian = subprocess.Popen([sys.executable, __file__, '--guardian'], stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=sys.stderr, text=True)
    guardian.stdin.write(json.dumps({'sink': sink, 'module': module, 'previous': previous}) + '\n')
    guardian.stdin.flush()
    stopping = threading.Event()
    packets = queue.Queue(maxsize=100)
    tcp = next(transport for transport in configuration['transports'] if transport['kind'] == 'snapcast')
    rtp = next((transport for transport in configuration['transports'] if transport['kind'] == 'rtp'), None)
    udp = create_rtp_socket() if rtp else None
    endpoint = urlparse(rtp['endpoint']) if rtp else None
    if udp:
        udp.bind((endpoint.username, 0))
    capture = None

    def transmit_tcp():
        make_realtime()
        while not stopping.is_set():
            try:
                with socket.create_connection((configuration['host'], tcp['tcpPort']), timeout=.5) as connection:
                    connection.settimeout(.1)
                    while not packets.empty():
                        try:
                            packets.get_nowait()
                        except queue.Empty:
                            break
                    while not stopping.is_set():
                        try:
                            connection.sendall(packets.get(timeout=.1))
                        except queue.Empty:
                            continue
            except OSError:
                stopping.wait(.1)

    for signal_number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signal_number, lambda *_: stopping.set())
    try:
        pulse('set-default-sink', sink)
        for item in json.loads(pulse('-f', 'json', 'list', 'sink-inputs')):
            pulse('move-sink-input', str(item['index']), sink)
        command = ['parec', '--raw', '--format=s16le', '--rate=48000', '--channels=2',
                   '--latency-msec=5', '--process-time-msec=2', '--device=' + sink + '.monitor']
        priority = realtime_priority()
        if priority:
            command = ['chrt', '--fifo', str(priority), *command]
        capture = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        make_realtime()
        threading.Thread(target=transmit_tcp, daemon=True).start()
        selector = selectors.DefaultSelector()
        selector.register(sys.stdin, selectors.EVENT_READ, 'owner')
        selector.register(capture.stdout, selectors.EVENT_READ, 'capture')
        last_owner = time.monotonic()
        last_capture = last_owner
        sequence = 0
        timestamp = 0
        source_id = int.from_bytes(os.urandom(4), 'big')
        buffered = bytearray()
        while not stopping.is_set() and time.monotonic() - last_owner < 3:
            if time.monotonic() - last_capture >= 3:
                raise RuntimeError('Desktop capture stopped advancing')
            for key, _ in selector.select(.1):
                if key.data == 'owner':
                    if not os.read(sys.stdin.fileno(), 4096):
                        stopping.set()
                    last_owner = time.monotonic()
                    continue
                data = os.read(capture.stdout.fileno(), 4096)
                if not data:
                    raise RuntimeError('Desktop capture stopped')
                last_capture = time.monotonic()
                buffered.extend(data)
                while len(buffered) >= 480:
                    frame = bytes(buffered[:480])
                    del buffered[:480]
                    if packets.full():
                        try:
                            packets.get_nowait()
                        except queue.Empty:
                            pass
                    packets.put_nowait(frame)
                    if udp:
                        values = struct.unpack('<240h', frame)
                        udp.sendto(struct.pack('!BBHII', 128, 127, sequence % 65536, timestamp % (2 ** 32), source_id) +
                                   struct.pack('!240h', *values), (endpoint.hostname, endpoint.port))
                    sequence += 1
                    timestamp += 120
    finally:
        stopping.set()
        if capture:
            capture.terminate()
            try:
                capture.wait(timeout=1)
            except subprocess.TimeoutExpired:
                capture.kill()
                capture.wait()
        if udp:
            udp.close()
        guardian.stdin.close()
        try:
            guardian.wait(timeout=5)
        except subprocess.TimeoutExpired:
            print('Desktop routing recovery is still running', file=sys.stderr)



def guard_routing():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    state = json.loads(sys.stdin.readline())
    sys.stdin.read()
    sink, previous = state['sink'], state['previous']
    try:
        if pulse('get-default-sink') == sink:
            pulse('set-default-sink', previous)
        sink_id = next((item['index'] for item in json.loads(pulse('-f', 'json', 'list', 'sinks')) if item['name'] == sink), None)
        for item in json.loads(pulse('-f', 'json', 'list', 'sink-inputs')):
            if item['sink'] == sink_id:
                pulse('move-sink-input', str(item['index']), previous)
    finally:
        pulse('unload-module', state['module'])


OUTPUTS = {'auto': 'SyrenSystem', 'stable': 'SyrenSystem_stable', 'fast': 'SyrenSystem_fast'}
ROUTER_APPLICATION = 'syrensystem-pc-router'


def is_router(stream):
    return stream.get('properties', {}).get('application.id') == ROUTER_APPLICATION


def restore_outputs(state):
    names = {sink['name'] for sink in state['sinks']}
    if pulse('get-default-sink') in names:
        pulse('set-default-sink', state['previous'])
    sinks = json.loads(pulse('-f', 'json', 'list', 'sinks'))
    identities = {sink['index'] for sink in sinks if sink['name'] in names}
    for stream in json.loads(pulse('-f', 'json', 'list', 'sink-inputs')):
        if stream['sink'] in identities and not is_router(stream):
            pulse('move-sink-input', str(stream['index']), state['previous'])
    for module in reversed(state.get('routers', [])):
        pulse('unload-module', module)
    for sink in reversed(state['sinks']):
        if sink['module'] is not None:
            pulse('unload-module', sink['module'])


def guard_outputs():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    state = None
    for line in sys.stdin:
        state = json.loads(line)
    if state is not None:
        restore_outputs(state)


def choose_output(mode):
    if mode not in OUTPUTS:
        raise ValueError('Choose automatic, stable or fast PC audio')
    sinks = json.loads(pulse('-f', 'json', 'list', 'sinks'))
    identities = {sink['index'] for sink in sinks if sink['name'] in OUTPUTS.values()}
    pulse('set-default-sink', OUTPUTS[mode])
    for stream in json.loads(pulse('-f', 'json', 'list', 'sink-inputs')):
        if stream['sink'] in identities and not is_router(stream):
            pulse('move-sink-input', str(stream['index']), OUTPUTS[mode])


def desktop_main(configuration):
    transports = configuration['transports']
    if not any(transport['kind'] == 'snapcast' for transport in transports):
        raise RuntimeError('Update SyrenServer before using the three PC outputs')
    directory = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'))
    lock = (directory / 'syrensystem-pc-audio.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state = {'previous': pulse('get-default-sink'), 'sinks': [], 'routers': []}
    guardian = subprocess.Popen([sys.executable, __file__, '--output-guardian'], stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=sys.stderr, text=True, pass_fds=(lock.fileno(),))
    stopping = threading.Event()
    failures = queue.SimpleQueue()
    captures = []
    workers = []

    if realtime_priority() != PRIORITY:
        guardian.stdin.close()
        guardian.wait(timeout=5)
        lock.close()
        raise RuntimeError('PC capture needs the user service real time limit of 86 or higher')

    def remember():
        guardian.stdin.write(json.dumps(state) + '\n')
        guardian.stdin.flush()

    def transmit_tcp(transport, packets):
        while not stopping.is_set():
            try:
                with socket.create_connection((configuration['host'], transport['tcpPort']), timeout=.5) as connection:
                    connection.settimeout(.1)
                    while not packets.empty():
                        try:
                            packets.get_nowait()
                        except queue.Empty:
                            break
                    while not stopping.is_set():
                        try:
                            connection.sendall(packets.get(timeout=.1))
                        except queue.Empty:
                            continue
            except OSError:
                stopping.wait(.1)

    def capture_audio(mode, capture, packets, endpoint):
        selector = selectors.DefaultSelector()
        selector.register(capture.stdout, selectors.EVENT_READ)
        connection = create_rtp_socket() if endpoint else None
        try:
            if connection:
                connection.bind((endpoint.username, 0))
            sequence = timestamp = 0
            source_id = int.from_bytes(os.urandom(4), 'big')
            buffered = bytearray()
            last_capture = time.monotonic()
            while not stopping.is_set():
                if time.monotonic() - last_capture >= 3:
                    raise RuntimeError(f'{mode} capture stopped advancing')
                if not selector.select(.1):
                    continue
                data = os.read(capture.stdout.fileno(), 4096)
                if not data:
                    raise RuntimeError(f'{mode} capture stopped')
                last_capture = time.monotonic()
                buffered.extend(data)
                while len(buffered) >= 480:
                    frame = bytes(buffered[:480])
                    del buffered[:480]
                    if packets is not None:
                        if packets.full():
                            try:
                                packets.get_nowait()
                            except queue.Empty:
                                pass
                        packets.put_nowait(frame)
                    if connection:
                        samples = struct.unpack('<240h', frame)
                        connection.sendto(struct.pack('!BBHII', 128, 127, sequence % 65536,
                            timestamp % (2 ** 32), source_id) + struct.pack('!240h', *samples),
                            (endpoint.hostname, endpoint.port))
                    sequence += 1
                    timestamp += 120
        except (OSError, RuntimeError) as error:
            failures.put(error)
            stopping.set()
        finally:
            selector.close()
            if connection:
                connection.close()

    def run_worker(target, arguments):
        try:
            make_realtime(required=True)
            target(*arguments)
        except (OSError, RuntimeError) as error:
            failures.put(error)
            stopping.set()

    def watch_outputs():
        previous = None
        last_default = OUTPUTS[configuration.get('mode', 'auto')]
        while not stopping.is_set():
            try:
                default = pulse('get-default-sink')
                if default in OUTPUTS.values() and default != last_default:
                    choose_output(next(mode for mode, name in OUTPUTS.items() if name == default))
                last_default = default
                sinks = json.loads(pulse('-f', 'json', 'list', 'sinks'))
                modes = {sink['index']: mode for sink in sinks for mode, name in OUTPUTS.items() if sink['name'] == name}
                active = sorted({modes[stream['sink']] for stream in json.loads(pulse('-f', 'json', 'list', 'sink-inputs'))
                                 if stream['sink'] in modes and not stream['corked'] and not is_router(stream)})
                status = {'mode': next((mode for mode, name in OUTPUTS.items() if name == default), None),
                          'activeModes': active, 'realtimePriority': realtime_priority(),
                          'senderPid': os.getpid(), 'capturePids': [capture.pid for capture in captures]}
                if status != previous:
                    print(json.dumps(status), flush=True)
                    previous = status
            except (OSError, subprocess.SubprocessError, ValueError) as error:
                failures.put(error)
                stopping.set()
            stopping.wait(.25)

    for signal_number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signal_number, lambda *_: stopping.set())
    try:
        remember()
        existing = {sink['name'] for sink in json.loads(pulse('-f', 'json', 'list', 'sinks'))}
        for mode, name in OUTPUTS.items():
            if name in existing and mode != 'auto':
                raise RuntimeError('Another PC audio session already owns the desktop outputs')
            module = None if name in existing else pulse('load-module', 'module-null-sink', 'sink_name=' + name,
                'rate=48000', 'channels=2', 'format=s16le', 'sink_properties=device.description=' + name)
            state['sinks'].append({'name': name, 'module': module})
            remember()
        pulse('set-default-sink', OUTPUTS[configuration.get('mode', 'auto')])
        for stream in json.loads(pulse('-f', 'json', 'list', 'sink-inputs')):
            pulse('move-sink-input', str(stream['index']), OUTPUTS[configuration.get('mode', 'auto')])
        for mode in ('stable', 'fast'):
            module = pulse('load-module', 'module-loopback', 'source=' + OUTPUTS[mode] + '.monitor',
                'sink=' + OUTPUTS['auto'], 'latency_msec=1', 'source_dont_move=true', 'sink_dont_move=true',
                'sink_input_properties=application.id=' + ROUTER_APPLICATION + ' media.role=filter')
            state['routers'].append(module)
            remember()
        tcp = next(transport for transport in transports if transport['kind'] == 'snapcast')
        rtp = next((transport for transport in transports if transport['kind'] == 'rtp'), None)
        packets = queue.Queue(maxsize=100)
        worker = threading.Thread(target=run_worker, args=(transmit_tcp, (tcp, packets)), daemon=True)
        worker.start()
        workers.append(worker)
        capture = subprocess.Popen(['chrt', '--fifo', str(PRIORITY), 'parec', '--raw', '--format=s16le',
            '--rate=48000', '--channels=2', '--latency-msec=2', '--process-time-msec=2',
            '--device=' + OUTPUTS['auto'] + '.monitor'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        captures.append(capture)
        worker = threading.Thread(target=run_worker,
            args=(capture_audio, ('PC audio', capture, packets, urlparse(rtp['endpoint']) if rtp else None)), daemon=True)
        worker.start()
        workers.append(worker)
        watcher = threading.Thread(target=watch_outputs, daemon=True)
        watcher.start()
        workers.append(watcher)
        selector = selectors.DefaultSelector()
        selector.register(sys.stdin, selectors.EVENT_READ)
        last_owner = time.monotonic()
        buffered = b''
        while not stopping.is_set() and time.monotonic() - last_owner < 3:
            if not selector.select(.1):
                continue
            data = os.read(sys.stdin.fileno(), 4096)
            if not data:
                break
            last_owner = time.monotonic()
            buffered += data
            while b'\n' in buffered:
                line, buffered = buffered.split(b'\n', 1)
                if line.startswith(b'{'):
                    message = json.loads(line)
                    if 'mode' in message:
                        choose_output(message['mode'])
        selector.close()
        if not failures.empty():
            raise failures.get()
    finally:
        stopping.set()
        for capture in captures:
            capture.terminate()
            try:
                capture.wait(timeout=1)
            except subprocess.TimeoutExpired:
                capture.kill()
                capture.wait()
        for worker in workers:
            worker.join(timeout=1)
        guardian.stdin.close()
        guardian.wait(timeout=5)
        lock.close()


def main():
    configuration = json.loads(sys.stdin.readline())
    desktop_main(configuration) if configuration.get('desktopOutputs') else legacy_main(configuration)


if __name__ == '__main__':
    try:
        if '--guardian' in sys.argv:
            guard_routing()
        elif '--output-guardian' in sys.argv:
            guard_outputs()
        else:
            main()
    except Exception as error:
        print('PC audio stopped: ' + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
