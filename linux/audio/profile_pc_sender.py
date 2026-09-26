#!/usr/bin/python3
"""Keep desktop capture alive only while its owning app is responding."""

import json
import os
import queue
import selectors
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse


def pulse(*arguments):
    return subprocess.check_output(['pactl', *arguments], text=True, timeout=2).strip()


def main():
    configuration = json.loads(sys.stdin.readline())
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
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM) if rtp else None
    endpoint = urlparse(rtp['endpoint']) if rtp else None
    if udp:
        udp.bind((endpoint.username, 0))
    capture = None

    def transmit_tcp():
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
        capture = subprocess.Popen(['parec', '--raw', '--format=s16le', '--rate=48000', '--channels=2',
                                    '--latency-msec=5', '--process-time-msec=2', '--device=' + sink + '.monitor'],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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


if __name__ == '__main__':
    try:
        guard_routing() if '--guardian' in sys.argv else main()
    except Exception as error:
        print('PC audio stopped: ' + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
