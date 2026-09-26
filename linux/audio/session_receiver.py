#!/usr/bin/python3
"""Apply the shared session catalogue at one physical speaker."""

import argparse
import json
from pathlib import Path
import queue
import signal
import subprocess
import threading
import time
import uuid

from common import atomic_json
from session_graph import SessionOutputGraph
from session_selection import OrderedPlaybackState, select_sessions, select_transport


PREFIX = 'SyrenSystem/v3/'
INTERRUPTION_GRACE = 3
REBUILD_AFTER_SECONDS = 10
INPUT_RETRY_SECONDS = 2
METADATA_ERRORS = (ValueError, KeyError, TypeError)
OPERATION_ERRORS = (RuntimeError, OSError, subprocess.SubprocessError, StopIteration)


class SessionReceiver:
    def __init__(self, configuration, graph, publish):
        self.configuration = configuration
        self.graph = graph
        self.publish = publish
        self.state = OrderedPlaybackState(configuration['state_id'])
        self.incoming = queue.SimpleQueue()
        self.stopped = threading.Event()
        self.instance = uuid.uuid4().hex
        self.sequence = 0
        self.selected = ()
        self.reasons = {}
        self.error = None
        self.last_report = 0
        self.last_status = None
        self.incoherent_since = None
        self.failed_since = {}
        self.last_graph_check = 0
        self.cold_since = {}
        self.input_failures = {}
        self.failing_since = None

    def receive(self, kind, payload):
        self.incoming.put((kind, payload))

    def tick(self):
        while not self.incoming.empty():
            kind, payload = self.incoming.get()
            self.state.receive(kind, payload)
        if not self.state.coherent():
            self.incoherent_since = self.incoherent_since or time.monotonic()
            configuration = self.state.messages.get('Configuration', {})
            group = next((group for group in configuration.get('groups', [])
                          if self.configuration['speaker_id'] in group['speakerIds']), {})
            if time.monotonic() - self.incoherent_since >= 3 or group.get('muted') or not configuration.get('playbackActivated'):
                self.graph.apply({})
                self.selected = ()
            self.report()
            return
        self.incoherent_since = None
        configuration = self.state.messages['Configuration']
        catalogue = self.state.messages['Catalogue']
        gains = self.state.messages['Gains']
        speaker_id = self.configuration['speaker_id']
        bindings = self.state.messages.get('Bindings', {}).get('clients', {})
        if time.monotonic() - self.last_graph_check >= 0.2:
            self.graph.repair_links()
            self.last_graph_check = time.monotonic()
        inputs = {item['transportId']: item for item in self.graph.status()}
        now = time.monotonic()
        health = {}
        failed = set()
        listed = {transport['id'] for session in catalogue['sessions'] for transport in session['transports']}
        self.input_failures = {identity: since for identity, since in self.input_failures.items() if identity in listed}
        for session in catalogue['sessions']:
            known = []
            for transport in session['transports']:
                if transport['id'] in self.input_failures:
                    # An input that could not be created counts as silent at this speaker.
                    health[transport['id']] = False
                    known.append(False)
                elif transport['kind'] == 'rtp':
                    healthy = inputs.get(transport['id'], {}).get('receiving', False)
                    health[transport['id']] = healthy
                    if transport.get('speakerId') == speaker_id and transport['id'] in inputs:
                        known.append(healthy)
                elif transport['id'] in inputs:
                    item = inputs[transport['id']]
                    healthy = item['receiving'] and bindings.get(item['clientId']) == transport['endpoint']
                    health[transport['id']] = healthy
                    known.append(healthy)
            if known and not any(known):
                # Inputs that stay silent here make the session unavailable at this speaker only.
                if now - self.failed_since.setdefault(session['id'], now) >= INTERRUPTION_GRACE:
                    failed.add(session['id'])
            else:
                self.failed_since.pop(session['id'], None)
        present = {session['id'] for session in catalogue['sessions']}
        self.failed_since = {identity: since for identity, since in self.failed_since.items() if identity in present}
        result = select_sessions(catalogue, configuration, gains['gains'].get(speaker_id, {}), speaker_id, failed=failed)
        by_identity = {session['id']: session for session in catalogue['sessions']}
        for session_id in result.receiving:
            session = by_identity[session_id]
            for transport in session['transports']:
                if transport['kind'] == 'snapcast' and transport.get('available'):
                    self.ensure(transport, now, lambda: self.graph.ensure_snapcast(
                        session_id, transport, expect_audio=session['state'] == 'playing'))
                elif transport['kind'] == 'rtp' and transport.get('speakerId') == speaker_id and transport.get('available'):
                    self.ensure(transport, now, lambda: self.graph.ensure_rtp(session_id, transport))
        gains_by_transport = {}
        for session_id in result.selected:
            transport = select_transport(by_identity[session_id], speaker_id, health)
            if transport:
                item = inputs.get(transport['id'])
                if item and health.get(transport['id']):
                    gains_by_transport[transport['id']] = result.gains[session_id]
        self.graph.apply(gains_by_transport)
        for item in self.graph.status():
            transport_id = item['transportId']
            session = by_identity.get(item['sessionId'])
            if item['sessionId'] in result.receiving:
                self.cold_since.pop(transport_id, None)
            else:
                self.cold_since.setdefault(transport_id, now)
            cold = transport_id in self.cold_since and now - self.cold_since[transport_id] >= INTERRUPTION_GRACE
            if not session or session['state'] == 'ended' or cold or result.reasons.get(item['sessionId']) in ('outside destination', 'source disabled'):
                self.graph.remove(transport_id)
                self.cold_since.pop(transport_id, None)
        self.selected, self.reasons = result.selected, result.reasons
        self.error = None
        self.report()

    def ensure(self, transport, now, create):
        # One input that cannot be created must not silence the other sessions on this speaker.
        failed_at = self.input_failures.get(transport['id'])
        if failed_at is not None and now - failed_at < INPUT_RETRY_SECONDS:
            return
        try:
            create()
        except METADATA_ERRORS + OPERATION_ERRORS as error:
            self.input_failures[transport['id']] = now
            logger = getattr(self.graph, 'logger', None)
            if logger:
                logger.warning('Could not create input %s: %s: %s', transport['id'], type(error).__name__, error)
        else:
            self.input_failures.pop(transport['id'], None)

    def report(self):
        inputs = self.graph.status()
        status = {
            'protocolVersion': 3, 'generation': self.state.generation,
            'speakerId': self.configuration['speaker_id'], 'physicalClientId': self.configuration['physical_id'],
            'instanceId': self.instance, 'bootSequence': self.configuration['boot_sequence'], 'ready': self.error is None,
            'capabilities': ['sessions', 'mixing', 'snapcast', 'rtp'],
            'selected': list(self.selected),
            'receiving': sorted({item['sessionId'] for item in inputs if item['receiving']}),
            'audible': sorted({item['sessionId'] for item in inputs if item['receiving'] and not item['muted'] and item['gain'] > 0}),
            'inputs': inputs, 'reasons': self.reasons, 'error': self.error,
        }
        serialized = json.dumps(status, sort_keys=True)
        if serialized != self.last_status or time.monotonic() - self.last_report >= 0.75:
            self.sequence += 1
            self.publish(dict(status, sequence=self.sequence))
            self.last_status, self.last_report = serialized, time.monotonic()

    def step(self):
        try:
            self.tick()
        except METADATA_ERRORS as error:
            self.fail(f'Invalid playback metadata: {type(error).__name__}')
        except OPERATION_ERRORS as error:
            self.fail(f'Audio graph operation failed: {type(error).__name__}')
            self.failing_since = self.failing_since or time.monotonic()
            if not self.graph.healthy() or time.monotonic() - self.failing_since >= REBUILD_AFTER_SECONDS:
                self.rebuild()
        else:
            self.failing_since = None

    def fail(self, message):
        self.error = message
        try:
            self.graph.apply({})
        except OPERATION_ERRORS:
            pass
        self.report()

    def rebuild(self):
        # Only a broken output graph is rebuilt; single failed operations are retried on the next tick.
        self.graph.stop(cancel=False)
        self.selected = ()
        self.failed_since.clear()
        self.cold_since.clear()
        self.input_failures.clear()
        self.failing_since = None
        self.graph.start()

    def run(self):
        try:
            self.graph.start()
            while not self.stopped.is_set():
                self.step()
                self.stopped.wait(0.02)
        finally:
            self.graph.stop()


def main():
    import paho.mqtt.client as mqtt

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path('/etc/syrensystem/session-receiver.json'))
    arguments = parser.parse_args()
    configuration = json.loads(arguments.config.read_text())
    epoch_path = Path(configuration.get('epoch_path', '/var/lib/syren-sessions/boot.json'))
    previous = json.loads(epoch_path.read_text()) if epoch_path.exists() else 0
    configuration['boot_sequence'] = previous + 1
    epoch_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_json(epoch_path, configuration['boot_sequence'])
    graph = SessionOutputGraph(Path(configuration.get('runtime_dir', '/run/syren-sessions')), configuration['device'],
                               configuration['hardware_path'], configuration['physical_id'], configuration['snapcast_host'],
                               configuration.get('snapcast_port', 1704))
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id='syren-session-' + configuration['physical_id'])
    client.reconnect_delay_set(min_delay=1, max_delay=2)
    receiver = SessionReceiver(configuration, graph, lambda status: client.publish(PREFIX + 'ReceiverStatus', json.dumps(status), qos=1))

    def connected(client, userdata, flags, reason_code, properties):
        if reason_code == 0:
            client.subscribe([(PREFIX + topic, 1) for topic in ('Configuration', 'Catalogue', 'Gains', 'Bindings')])

    def message(client, userdata, message):
        try:
            receiver.receive(message.topic.removeprefix(PREFIX), json.loads(message.payload))
        except (ValueError, UnicodeDecodeError):
            receiver.error = 'Invalid playback message'

    client.on_connect = connected
    client.on_message = message
    client.connect_async(configuration['mqtt_host'], configuration.get('mqtt_port', 1883), keepalive=5)
    client.loop_start()
    for signal_number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signal_number, lambda *_: receiver.stopped.set())
    try:
        receiver.run()
    finally:
        client.disconnect()
        client.loop_stop()


if __name__ == '__main__':
    main()
