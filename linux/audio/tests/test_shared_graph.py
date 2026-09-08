import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from shared_graph import SharedAudioGraph


def node(identifier, name):
    return {'id': identifier, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': name}}}


def port(identifier, parent, channel, direction):
    return {'id': identifier, 'type': 'PipeWire:Interface:Port', 'info': {'props': {
        'node.id': parent, 'audio.channel': channel, 'port.direction': direction}}}


def link(output, target):
    return {'type': 'PipeWire:Interface:Link', 'info': {'props': {
        'link.output.port': output, 'link.input.port': target}}}


class SharedGraphTests(unittest.TestCase):
    def test_recreated_ports_on_same_node_are_reconnected(self):
        graph = SharedAudioGraph.__new__(SharedAudioGraph)
        graph.command = Mock()
        fixed = [node(33, 'syren_snapclient'), node(27, 'syren_snapcast_gain'),
                 port(28, 27, 'FL', 'in'), port(29, 27, 'FR', 'in')]
        first = fixed + [port(44, 33, 'FL', 'out'), port(45, 33, 'FR', 'out')]
        graph.connect_snapcast(first)
        self.assertEqual(graph.command.call_count, 2)
        graph.command.reset_mock()
        graph.connect_snapcast(first + [link(44, 28), link(45, 29)])
        graph.command.assert_not_called()
        graph.connect_snapcast(fixed + [port(46, 33, 'FL', 'out'), port(49, 33, 'FR', 'out')])
        graph.command.assert_any_call('pw-link', '46', '28')
        graph.command.assert_any_call('pw-link', '49', '29')

    def test_missing_link_is_repaired_even_when_ports_are_unchanged(self):
        graph = SharedAudioGraph.__new__(SharedAudioGraph)
        graph.command = Mock()
        objects = [node(33, 'syren_snapclient'), node(27, 'syren_snapcast_gain'),
                   port(28, 27, 'FL', 'in'), port(29, 27, 'FR', 'in'),
                   port(46, 33, 'FL', 'out'), port(49, 33, 'FR', 'out'), link(46, 28)]
        graph.connect_snapcast(objects)
        graph.command.assert_called_once_with('pw-link', '49', '29')
