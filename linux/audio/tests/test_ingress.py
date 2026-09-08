import socket
import struct
import sys
from pathlib import Path
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ingress import Ingress, PacketFilter


def packet(sequence=1, timestamp=None, source_id=42):
    if timestamp is None:
        timestamp = sequence * 120 % (2 ** 32)
    return struct.pack('!BBHII', 0x80, 127, sequence % 65536, timestamp, source_id) + bytes(480)


class IngressTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.filter = PacketFilter('192.168.1.2', 60, lambda: self.now)
        self.address = ('192.168.1.2', 50000)

    def test_latches_only_valid_source_and_format(self):
        self.assertFalse(self.filter.accept(packet(), ('192.168.1.3', 50000)))
        self.assertFalse(self.filter.accept(packet()[:-1], self.address))
        self.assertIsNone(self.filter.source)
        self.assertTrue(self.filter.accept(packet(), self.address))
        self.assertEqual(self.filter.source, (50000, 42))

    def test_wrong_port_and_ssrc_cannot_relearn(self):
        self.filter.accept(packet(), self.address)
        self.assertFalse(self.filter.accept(packet(2), (self.address[0], 50001)))
        self.assertFalse(self.filter.accept(packet(2, source_id=43), self.address))
        self.assertEqual(self.filter.source, (50000, 42))
        self.assertTrue(self.filter.identity_changed)
        self.assertEqual(self.filter.rejected['tuple'], 2)

    def test_duplicates_stale_and_bad_timestamps_do_not_refresh_reception(self):
        self.filter.accept(packet(10), self.address)
        self.now = 1
        for content in (packet(10), packet(9), packet(11, timestamp=123)):
            self.assertFalse(self.filter.accept(content, self.address))
        self.assertEqual(self.filter.last_received, 0)

    def test_sequence_and_timestamp_wrap(self):
        self.filter.accept(packet(65535, timestamp=2 ** 32 - 120), self.address)
        self.assertTrue(self.filter.accept(packet(0, timestamp=0), self.address))

    def test_stability_resets_after_gap(self):
        for count in range(501):
            self.now = count * 0.0025
            self.filter.accept(packet(count), self.address)
        self.assertTrue(self.filter.stable())
        self.now += 0.101
        self.filter.accept(packet(501), self.address)
        self.assertFalse(self.filter.stable())

    def test_startup_latch_expires(self):
        self.now = 61
        self.assertFalse(self.filter.accept(packet(), self.address))
        self.assertEqual(self.filter.rejected['startup_expired'], 1)

    def test_closing_disposes_sockets_and_queued_datagrams(self):
        ingress = Ingress('127.0.0.1', PacketFilter('127.0.0.1', time.monotonic() + 60), port=0)
        ingress.prepare()
        ingress.open()
        old_listener, old_forwarder = ingress.listener, ingress.forwarder
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
            sender.sendto(packet(), old_listener.getsockname())
        ingress.close()
        self.assertEqual(old_listener.fileno(), -1)
        self.assertEqual(old_forwarder.fileno(), -1)
        ingress.prepare()
        ingress.open()
        with self.assertRaises(BlockingIOError):
            ingress.listener.recvfrom(2048)
        ingress.close()


if __name__ == '__main__':
    unittest.main()
