#!/usr/bin/env python3
"""Measure packet forwarding with real sockets and kernel timestamps."""

import json
import os
from pathlib import Path
import queue
import resource
import socket
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ingress import Ingress, PacketFilter


def measure():
    count = 1000
    sent_times = [0] * count
    failures = queue.Queue()
    ready = threading.Event()
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    packet_filter = PacketFilter('127.0.0.1', time.monotonic() + 10)
    ingress = Ingress('127.0.0.1', packet_filter, port=0)
    port = ingress.prepare()
    receiver.setsockopt(socket.SOL_SOCKET, 35, 1)
    receiver.bind(('127.0.0.1', port))
    receiver.settimeout(4)
    ingress.open()
    destination = ingress.listener.getsockname()

    def forward():
        try:
            os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(86))
            assert os.sched_getparam(0).sched_priority == 86
            ready.set()
            ingress.run()
        except BaseException as error:
            failures.put(error)
            ready.set()

    def transmit():
        try:
            os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(84))
            scheduled = time.monotonic()
            for sequence in range(count):
                content = struct.pack('!BBHII', 128, 127, sequence, sequence * 120, 42) + bytes(480)
                sent_times[sequence] = time.time_ns()
                sender.sendto(content, destination)
                scheduled += .0025
                time.sleep(max(0, scheduled - time.monotonic()))
        except BaseException as error:
            failures.put(error)

    forwarding = threading.Thread(target=forward)
    producer = threading.Thread(target=transmit)
    delays = []
    try:
        forwarding.start()
        assert ready.wait(2), 'Ingress did not start'
        if not failures.empty():
            raise failures.get()
        producer.start()
        for iteration in range(count):
            content, ancillary, _, _ = receiver.recvmsg(2048, 128)
            sequence = struct.unpack('!H', content[2:4])[0]
            timestamps = [struct.unpack('ll', data) for level, kind, data in ancillary
                          if level == socket.SOL_SOCKET and kind == 35]
            assert len(timestamps) == 1, 'Kernel packet timestamp is missing'
            seconds, nanoseconds = timestamps[0]
            if sequence >= 40:
                delays.append((seconds * 1000000000 + nanoseconds - sent_times[sequence]) / 1000000)
        producer.join(timeout=2)
        if not failures.empty():
            raise failures.get()
        assert packet_filter.accepted == count, 'Ingress lost valid packets'
        delays.sort()
        percentile = delays[int(.95 * (len(delays) - 1))]
        print(json.dumps({'packets': count, 'ingress_priority': 86,
                          'forwarding_delay_p95_msec': percentile,
                          'forwarding_delay_max_msec': max(delays)}), flush=True)
        assert percentile < .5, 'Ingress consumes too much of the RTP buffer before forwarding'
    finally:
        ingress.running = False
        ingress.close()
        forwarding.join(timeout=1)
        if producer.is_alive():
            producer.join(timeout=4)
        sender.close()
        receiver.close()


def main():
    if resource.getrlimit(resource.RLIMIT_RTPRIO)[0] < 86 and os.geteuid() != 0:
        return subprocess.run(['systemd-run', '--user', '--pipe', '--wait', '--collect', '--quiet',
            '--property=LimitRTPRIO=86', '--', sys.executable, str(Path(__file__).resolve())], check=False).returncode
    measure()
    return 0


if __name__ == '__main__':
    sys.exit(main())
