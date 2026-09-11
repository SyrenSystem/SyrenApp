"""Run production receiver controls with an in memory PipeWire device."""

import json
from pathlib import Path
import re
import struct
import sys
from types import SimpleNamespace
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'linux/audio'))
from ingress import PacketFilter
from session import Session
from shared_graph import SharedAudioGraph


class DeviceGraph(SharedAudioGraph):
    def __init__(self):
        self.volume = 10
        self.muted = True
        self.latency = 20
        self.period = 128
        self.output_id = 1
        self.selected_source = 'snapcast'
        self.snapcast_muted = True
        self.stops = 0
        self.writes = []
        self.properties = {
            1: {'mute': True, 'channelVolumes': [0.1, 0.1]},
            2: {'mute': True, 'channelVolumes': [1.0, 1.0]},
        }

    def command(self, *arguments):
        if arguments[0] == 'pw-cli':
            identifier = int(arguments[2])
            muted = 'mute = true' in arguments[4]
            volume = float(re.search(r'channelVolumes = \[ ([\d.]+)', arguments[4])[1])
            self.properties[identifier] = {'mute': muted, 'channelVolumes': [volume, volume]}
            audible = [identifier for identifier, properties in self.properties.items()
                       if not properties['mute'] and properties['channelVolumes'][0] > 0]
            if len(audible) > 1:
                raise AssertionError('Both audio branches became audible')
            self.writes.append({'node': identifier, 'muted': muted, 'volume': volume})
            return SimpleNamespace(stdout='')
        if arguments != ('pw-dump',):
            raise AssertionError(f'Unexpected device operation: {arguments}')
        return SimpleNamespace(stdout=json.dumps([
            {'id': identifier, 'info': {'props': {'node.name': f'syren_{name}_gain'},
                                      'params': {'Props': [self.properties[identifier]]}}}
            for identifier, name in [(1, 'rtp'), (2, 'snapcast')]
        ]))

    def start(self):
        self.standby()

    def stop(self):
        self.stops += 1
        return True

    def dispose(self):
        pass


class Receiver:
    def __init__(self):
        self.now = 0
        self.sequence = 0
        self.session = None
        self.graphs = []
        self.starts = 0
        self.opted_in = False

    def graph(self, port):
        graph = DeviceGraph()
        self.graphs.append(graph)
        return graph

    def advance(self, count=4):
        for index in range(count):
            self.now += .0025
            self.sequence += 1
            packet = struct.pack('!BBHII', 128, 127, self.sequence % 65536,
                                 self.sequence * 120 % (2 ** 32), 42) + bytes(480)
            self.session.ingress.filter.accept(packet, ('127.0.0.1', 50000))
        self.session.last_heartbeat = self.now
        self.session.health_at = self.now
        self.session.tick()

    def request(self, request):
        action = request['action']
        if action == 'opt-in':
            self.opted_in = request['enabled']
        elif action == 'start':
            if self.session is not None:
                raise ValueError('A running session must not restart')
            self.starts += 1
            ingress = Mock(discarded=0)
            ingress.filter = PacketFilter('127.0.0.1', self.now + 60, lambda: self.now)
            self.session = Session(str(self.starts), ingress, self.graph,
                                   Mock(side_effect=AssertionError('Unexpected escalation')),
                                   clock=lambda: self.now)
            self.session.start()
            self.advance(440)
        elif action in ('stop', 'close'):
            if self.session:
                self.session.stop()
            self.session = None
        elif self.session:
            self.advance()
            if action == 'fixture-recover':
                self.session.begin_recovery('Injected packet interruption')
                self.session.rebuild()
                self.session.ingress.filter.reset_reception()
                self.advance(440)
            else:
                self.session.request({**request, 'session': request.get('session', self.session.session),
                                      'action': 'heartbeat' if action == 'app-heartbeat' else action})
        response = self.session.status() if self.session else {
            'version': 1, 'state': 'idle', 'session': None, 'muted': True,
        }
        return {**response, 'preferences': {'opt_in': self.opted_in,
                'pairing': {'snapclient_id': 'receiver'}},
                'fixture': {'starts': self.starts, 'graphs': len(self.graphs),
                            'stops': sum(graph.stops for graph in self.graphs),
                            'writes': self.graphs[-1].writes[-30:] if self.graphs else []}}


if __name__ == '__main__':
    receiver = Receiver()
    for line in sys.stdin:
        try:
            print(json.dumps(receiver.request(json.loads(line))), flush=True)
        except Exception as error:
            print(json.dumps({'version': 1, 'error': str(error)}), flush=True)
