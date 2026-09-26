"""Restrict UDP on the trusted LAN without claiming authentication."""

from collections import Counter
import ipaddress
import socket
import struct
import threading
import time


# Seconds of steady packets before a session speaker trusts RTP again.
RECOVERY_SECONDS = 3
# Seconds without packets before a session speaker stops trusting RTP.
OUTAGE_SECONDS = 0.5


class PacketFilter:
    def __init__(self, sender_address, startup_deadline, clock=time.monotonic):
        self.sender_address = str(ipaddress.IPv4Address(sender_address))
        self.startup_deadline = startup_deadline
        self.clock = clock
        self.source = None
        self.sequence = None
        self.timestamp = None
        self.last_received = None
        self.last_received_wall = None
        self.stable_since = None
        self.accepted = 0
        self.rejected = Counter()
        self.identity_changed = False
        self.trusted = False

    def accept(self, packet, address):
        now = self.clock()
        reason = None
        if address[0] != self.sender_address:
            reason = 'address'
        elif len(packet) != 492 or packet[0] != 0x80 or packet[1] & 127 != 127:
            reason = 'format'
        else:
            header, payload, sequence, timestamp, source_id = struct.unpack('!BBHII', packet[:12])
            source = (address[1], source_id)
            if self.source is None:
                if now > self.startup_deadline:
                    reason = 'startup_expired'
                else:
                    self.source = source
            elif self.source != source:
                reason = 'tuple'
                self.identity_changed = True
            if not reason and self.sequence is not None:
                advance = (sequence - self.sequence) % 65536
                if not 0 < advance < 32768:
                    reason = 'duplicate_or_stale'
                elif (timestamp - self.timestamp) % (2 ** 32) != advance * 120:
                    reason = 'timestamp'
                    self.identity_changed = True
            if not reason:
                if self.last_received is None or now - self.last_received > 0.1:
                    self.stable_since = now
                self.sequence, self.timestamp = sequence, timestamp
                self.last_received = now
                self.last_received_wall = time.time()
                self.accepted += 1
                return True
        self.rejected[reason] += 1
        return False

    def reset_reception(self):
        self.stable_since = None
        self.last_received = None
        self.trusted = False

    def stable(self):
        now = self.clock()
        return (self.stable_since is not None and self.last_received is not None
                and now - self.stable_since >= 1 and now - self.last_received <= 0.1)

    def usable(self):
        # Short Wi-Fi gaps keep RTP in use, so a speaker does not jump between RTP and the delayed Snapcast copy.
        now = self.clock()
        if self.last_received is None or now - self.last_received > OUTAGE_SECONDS:
            self.trusted = False
        elif not self.trusted and self.stable_since is not None and (
                now - self.stable_since >= RECOVERY_SECONDS and now - self.last_received <= 0.1):
            self.trusted = True
        return self.trusted

    def status(self):
        return {'accepted': self.accepted, 'rejected': dict(self.rejected),
                'source_port': self.source[0] if self.source else None,
                'ssrc': self.source[1] if self.source else None,
                'last_received_monotonic': self.last_received,
                'last_received_at': self.last_received_wall,
                'last_rtp_timestamp': self.timestamp, 'sequence': self.sequence,
                'identity_changed': self.identity_changed}


class Ingress:
    def __init__(self, bind_address, packet_filter, port=46000):
        self.bind_address = str(ipaddress.IPv4Address(bind_address))
        if self.bind_address == '0.0.0.0':
            raise ValueError('Select a receiving interface IPv4 address')
        self.port = port
        self.filter = packet_filter
        self.lock = threading.Lock()
        self.listener = None
        self.forwarder = None
        self.gate = False
        self.running = True
        self.discarded = 0

    def prepare(self):
        self.close()
        with self.lock:
            self.forwarder = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.forwarder.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.forwarder.bind(('127.0.0.2', 0))
            return self.forwarder.getsockname()[1]

    def open(self):
        with self.lock:
            self.listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
            self.listener.bind((self.bind_address, self.port))
            self.listener.setblocking(False)
            self.filter.reset_reception()
            self.gate = True

    def close(self):
        with self.lock:
            self.gate = False
            for connection in (self.listener, self.forwarder):
                if connection:
                    connection.close()
            self.listener = self.forwarder = None
            self.filter.reset_reception()

    def close_gate(self):
        with self.lock:
            self.gate = False

    def run(self):
        while self.running:
            received = False
            with self.lock:
                if self.listener:
                    try:
                        packet, address = self.listener.recvfrom(2048)
                        received = True
                        if self.gate and self.filter.accept(packet, address):
                            self.forwarder.sendto(packet, ('127.0.0.1', self.forwarder.getsockname()[1]))
                        elif not self.gate:
                            self.discarded += 1
                    except BlockingIOError:
                        pass
            if not received:
                time.sleep(0.001)
