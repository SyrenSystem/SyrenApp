#!/usr/bin/env python3
"""Summarize RTP packet captures without treating them as playback latency."""

import argparse
import csv
import json
from pathlib import Path
import random
import statistics


class PacketStatistics:
    def __init__(self):
        self.streams = {}
        self.intervals = []
        self.interval_count = 0
        self.maximum_gap_ms = 0
        self.random = random.Random(0)
        self.invalid_payload_packets = 0

    def add(self, arrival, stream_id, sequence, timestamp, udp_length):
        if udp_length != 500:
            self.invalid_payload_packets += 1
        if stream_id not in self.streams:
            self.streams[stream_id] = {'first': sequence, 'highest': sequence, 'recent': {sequence},
                'unique': 1, 'duplicates': 0, 'reordered': 0, 'too_old': 0,
                'arrival': arrival, 'timestamp': timestamp, 'jitter_ms': 0}
            return
        stream = self.streams[stream_id]
        extended = stream['highest'] + ((sequence - stream['highest'] + 32768) % 65536 - 32768)
        if extended < stream['highest'] - 8192:
            stream['too_old'] += 1
            return
        if extended in stream['recent']:
            stream['duplicates'] += 1
            return
        if extended < stream['highest']:
            stream['reordered'] += 1
        stream['recent'].add(extended)
        stream['unique'] += 1
        stream['first'] = min(stream['first'], extended)
        stream['highest'] = max(stream['highest'], extended)
        if len(stream['recent']) > 16384:
            stream['recent'] = {number for number in stream['recent'] if number >= stream['highest'] - 8192}
        interval_ms = (arrival - stream['arrival']) * 1000
        media_interval_ms = ((timestamp - stream['timestamp'] + 2 ** 31) % 2 ** 32 - 2 ** 31) / 48
        variation = abs(interval_ms - media_interval_ms)
        stream['jitter_ms'] += (variation - stream['jitter_ms']) / 16
        stream['arrival'], stream['timestamp'] = arrival, timestamp
        self.maximum_gap_ms = max(self.maximum_gap_ms, interval_ms)
        self.interval_count += 1
        if len(self.intervals) < 10000:
            self.intervals.append(interval_ms)
        else:
            selected = self.random.randrange(self.interval_count)
            if selected < len(self.intervals):
                self.intervals[selected] = interval_ms

    def result(self):
        streams = {}
        for stream_id, stream in self.streams.items():
            streams[stream_id] = {key: value for key, value in stream.items()
                                  if key not in ['recent', 'arrival', 'timestamp', 'first', 'highest']}
            streams[stream_id]['unseen_sequence_numbers'] = stream['highest'] - stream['first'] + 1 - stream['unique']
        intervals = sorted(self.intervals)
        return {'streams': streams, 'sampled_intervals': len(intervals),
                'median_interarrival_ms': statistics.median(intervals) if intervals else None,
                'p95_interarrival_ms': intervals[int((len(intervals) - 1) * 0.95)] if intervals else None,
                'maximum_interarrival_ms': self.maximum_gap_ms,
                'packets_without_480_byte_pcm_payload': self.invalid_payload_packets,
                'interpretation': 'Capture arrival timing only. Missing sequence numbers can include capture loss. Check tcpdump drop counters. Split captures at long interruptions and restarts; RTP sequence unwrapping is ambiguous beyond 32768 packets.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tsv', help='tshark fields: frame.time_epoch, rtp.ssrc, rtp.seq, rtp.timestamp, udp.length')
    parser.add_argument('--output', required=True)
    arguments = parser.parse_args()
    statistics = PacketStatistics()
    with Path(arguments.tsv).open() as source:
        for row in csv.reader(source, delimiter='\t'):
            if len(row) != 5 or not all(row):
                raise ValueError('Expected five tshark fields per row')
            statistics.add(float(row[0]), row[1], int(row[2]), int(row[3]), int(row[4]))
    if not statistics.streams:
        raise ValueError('No RTP packets found')
    result = statistics.result()
    Path(arguments.output).write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
