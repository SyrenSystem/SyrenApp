"""Serve the unprivileged receiver and its priority mute socket."""

import json
import logging
import logging.handlers
import os
from pathlib import Path
import signal
import socket
import threading
import time

from common import VERSION, exchange, peer_credentials, read_json, receive, send
from shared_graph import SharedAudioGraph
from ingress import Ingress, PacketFilter
from session import Session


RUNTIME = Path('/run/syren-rtp-audio')
BROKER = Path('/run/syren-rtp-broker.sock')


def serve(path, session, priority=False):
    path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(path))
        os.chmod(path, 0o600)
        listener.listen(8)
        listener.settimeout(0.2)

        def handle(connection):
            with connection:
                connection.settimeout(2)
                try:
                    process_id, user_id, group_id = peer_credentials(connection)
                    if user_id != 0:
                        raise PermissionError('Only the receiver broker can control audio')
                    request = receive(connection)
                    if priority and request.get('action') != 'mute':
                        raise ValueError('The priority socket only accepts mute')
                    result = session.request(request)
                except Exception as error:
                    result = {'version': VERSION, 'error': str(error)}
                try:
                    send(connection, result)
                except OSError:
                    pass

        while not session.closed.is_set():
            try:
                connection, address = listener.accept()
                threading.Thread(target=handle, args=(connection,), daemon=True).start()
            except socket.timeout:
                continue


def main():
    configuration = read_json('/run/syren-rtp/session.json')
    RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
    packet_filter = PacketFilter(configuration['sender_address'], time.monotonic() + 60)
    ingress = Ingress(configuration['bind_address'], packet_filter)
    graph_count = 0

    def graph_factory(port):
        nonlocal graph_count
        graph_count += 1
        return SharedAudioGraph(RUNTIME / f'graph-{graph_count}', configuration['latency'],
                          configuration['device'], configuration['hardware_path'], port, snapcast=configuration['snapcast'])

    def escalate():
        try:
            exchange(BROKER, {'version': VERSION, 'action': 'worker-failed',
                              'session': configuration['session']}, timeout=0.2)
        except Exception:
            os._exit(1)

    session = Session(configuration['session'], ingress, graph_factory, escalate)
    logger = logging.getLogger('telemetry')
    logger.setLevel(logging.INFO)
    logger.addHandler(logging.handlers.RotatingFileHandler(
        '/var/log/syren-rtp/telemetry.jsonl', maxBytes=1024 * 1024, backupCount=3))

    def health():
        while not session.closed.wait(0.5):
            graph = session.graph
            if graph and graph.period and not session.rebuilding:
                try:
                    graph.check_health()
                    if graph is session.graph:
                        session.graph_healthy = True
                        session.health_at = time.monotonic()
                except Exception as error:
                    if graph is session.graph and session.state in ('playing', 'readyMuted'):
                        logger.error('Graph health failed: %s', error)
                        session.fail('Graph health failed: ' + str(error))
            logger.info(json.dumps(session.status()))

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda received, frame: session.closed.set())
    for function, arguments in ((serve, (RUNTIME / 'control.sock', session)),
                                (serve, (RUNTIME / 'mute.sock', session, True)),
                                (ingress.run, ()), (health, ()), (session.start, ())):
        threading.Thread(target=function, args=arguments, daemon=True).start()
    try:
        while not session.closed.wait(0.05):
            session.tick()
    finally:
        session.stop()


if __name__ == '__main__':
    main()
