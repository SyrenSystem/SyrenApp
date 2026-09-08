#!/usr/bin/python3
"""Control opt in RTP without resuming playback after a restart."""

import fcntl
import json
import logging
import logging.handlers
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

from common import (VERSION, atomic_json, deadline, exchange, peer_credentials, process_alive,
                    process_identity, read_json, receive, remove_journal, run, send, validate_version)
from compatibility import probe
from pairing import Channel, Pairing
import routing


DIRECTORY = Path(__file__).resolve().parent
ROOT = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'syrensystem/rtp'
CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'syrensystem/rtp'
RUNTIME = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')) / 'syren-rtp-controller'
JOURNAL = ROOT / 'state.json'
DISABLED = Path('/usr/lib/syrensystem/rtp/disabled')


def cleanup(pairing, confirm=False, expected_session=None):
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (ROOT / 'cleanup.lock').open('a') as lock, deadline(60):
        expires = time.monotonic() + 1
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > expires:
                    raise RuntimeError('Another cleanup attempt is running')
                time.sleep(0.05)
        state = read_json(JOURNAL)
        if not state:
            return
        if expected_session is not None and state['session'] != expected_session:
            return
        errors = []
        for operation, label in ((lambda: routing.restore_routes(state), 'Local routes'),
                                  (lambda: routing.stop_process(state.get('sender_process')), 'RTP sender'),
                                  (lambda: routing.restore_sender(state, JOURNAL, confirm=confirm), 'Snapcast sender')):
            try:
                operation()
            except Exception as error:
                errors.append(label + ': ' + str(error))
        if state.get('remote_start_intended'):
            try:
                response = pairing.request(state['endpoint'], {'version': VERSION,
                    'action': 'recover' if confirm else 'stop', 'session': state['session'],
                    'confirm_snapclient_restore': confirm}, timeout=30)
                if response.get('state') != 'idle' or response.get('restored') is not True:
                    raise RuntimeError('Receiver restoration has not been confirmed')
            except Exception as error:
                errors.append('Receiver: ' + str(error))
        if errors:
            state['cleanup_errors'] = errors
            atomic_json(JOURNAL, state)
            raise RuntimeError('; '.join(errors))
        atomic_json(ROOT / 'last-state.json', dict(state, stopped_at=time.time()))
        remove_journal(JOURNAL)


class Controller:
    def __init__(self):
        self.pairing = Pairing(CONFIG)
        self.lifecycle = threading.Lock()
        self.stop_lock = threading.Lock()
        self.start_lock = threading.Lock()
        self.cancel = threading.Event()
        self.exiting = threading.Event()
        self.state = 'recoveryPending' if JOURNAL.exists() else 'idle'
        self.error = None
        self.session = None
        self.endpoint = None
        self.owner = None
        self.app_heartbeat = None
        self.receiver = {}
        self.channel = None
        self.priority = None
        self.guardian = None
        self.start_complete = False
        self.last_control = None
        self.mute_requested = None
        self.mute_pending = False
        self.mute_uncertain = False
        self.mute_serial = 0
        self.logger = logging.getLogger('controller')
        self.logger.setLevel(logging.INFO)
        ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.logger.addHandler(logging.handlers.RotatingFileHandler(
            ROOT / 'diagnostics.jsonl', maxBytes=1024 * 1024, backupCount=3))
        if JOURNAL.exists():
            threading.Thread(target=self.stop, daemon=True).start()
        threading.Thread(target=self.watch_owner, daemon=True).start()
        threading.Thread(target=self.monitor, daemon=True).start()

    def status(self):
        receiver = dict(self.receiver)
        state = self.state
        if self.start_complete and state not in ('stopping', 'recoveryPending', 'idle'):
            state = receiver.get('state', state)
        if self.mute_pending or self.mute_uncertain:
            receiver['muted'] = None
        return dict(receiver, version=VERSION, state=state, session=self.session,
                    generation=receiver.get('generation'), error=self.error or receiver.get('error'),
                    mute_pending=self.mute_pending, mute_unconfirmed=self.mute_uncertain,
                    preferences=self.pairing.preferences(), pending_recovery=JOURNAL.exists() and state == 'recoveryPending',
                    release_acceptance='outstanding')

    def preflight(self):
        report = probe()
        if DISABLED.exists() or (ROOT / 'disabled').exists():
            report['errors'].append('Package maintenance has disabled new starts')
        if JOURNAL.exists():
            report['errors'].append('Recovery is pending; restore the previous session before starting')
        try:
            snapshot = routing.snapshot()
            if routing.LIVE_SINK in snapshot['sinks'].values():
                report['errors'].append('A live RTP sink already exists; recover its owner first')
            endpoint = self.pairing.endpoint()
            remote = self.pairing.request(endpoint, {'version': VERSION, 'action': 'preflight'})
            report['receiver'] = remote
            if remote.get('shared_output') is not True:
                report['errors'].append('Update the receiver package to support connected source switching')
            if remote.get('version') != VERSION or remote.get('protocol') != VERSION:
                report['errors'].append('Protocol major mismatch; update both packages before starting')
            if not remote.get('ready'):
                report['errors'].extend(remote.get('errors', ['Receiver is not ready']))
            if remote.get('snapclient_id') != endpoint['snapclient_id']:
                report['errors'].append('Discovered Snapclient does not match the installed receiver identity')
            if remote.get('bind_address') != endpoint['address']:
                report['errors'].append('SSH endpoint must resolve to the selected receiving interface address')
            report['endpoint'] = endpoint
        except Exception as error:
            report['errors'].append(str(error))
        report['ready'] = not report['errors']
        return dict(report, version=VERSION)

    def start(self, request):
        try:
            with self.lifecycle, deadline(60, self.cancel):
                report = self.preflight()
                if not report['ready']:
                    raise RuntimeError('; '.join(report['errors']))
                self.endpoint = report['endpoint']
                self.guardian = subprocess.Popen([sys.executable, str(DIRECTORY / 'laptop.py'), '_guard', self.session],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
                state = {'version': VERSION, 'session': self.session, 'endpoint': self.endpoint,
                         'owner': self.owner, 'controller': process_identity(os.getpid()),
                         'routing': routing.snapshot(), 'started_at': time.time(), 'remote_start_intended': True}
                atomic_json(Path.home() / '.local/state/syrensystem/rtp-location.json', {
                    'state_home': str(ROOT.parent.parent), 'config_home': str(CONFIG.parent.parent),
                    'runtime': str(RUNTIME.parent)})
                atomic_json(JOURNAL, state)
                self.pairing.request(self.endpoint, {'version': VERSION, 'action': 'start',
                    'session': self.session, 'sender_address': self.endpoint['sender_address'],
                    'snapclient_id': self.endpoint['snapclient_id'], 'latency': 20}, timeout=30)
                self.channel = Channel(self.pairing, self.endpoint)
                self.priority = Channel(self.pairing, self.endpoint, priority=True)
                self.last_control = time.monotonic()
                if self.mute_pending:
                    self.mute()
                while not self.receiver.get('graph_healthy') or not self.receiver.get('negotiated', {}).get('period_frames'):
                    if self.cancel.wait(0.05):
                        raise RuntimeError('Startup cancelled')
                    from common import remaining
                    remaining(1)
                routing.handoff(state, JOURNAL)
                configuration = (DIRECTORY / 'templates/sender.conf.in').read_text()
                remote_name = os.environ.get('PIPEWIRE_REMOTE', 'pipewire-0')
                import re
                if not re.fullmatch('[A-Za-z0-9_.-]+', remote_name):
                    raise ValueError('Unsupported desktop PipeWire remote name')
                for key, value in {'REMOTE': remote_name, 'LOCAL_IP': self.endpoint['sender_address'],
                                   'PI_IP': self.endpoint['address']}.items():
                    configuration = configuration.replace('@' + key + '@', value)
                path = ROOT / 'sender.conf'
                path.write_text(configuration)
                state['sender_start_intended'] = True
                atomic_json(JOURNAL, state)
                self.guardian.stdin.write(b'{"action":"sender"}\n')
                self.guardian.stdin.flush()
                if not select.select([self.guardian.stdout], [], [], 3)[0]:
                    raise RuntimeError('Sender guardian did not acknowledge startup')
                response = json.loads(self.guardian.stdout.readline())
                if response.get('error'):
                    raise RuntimeError(response['error'])
                state = read_json(JOURNAL)
                while routing.LIVE_SINK not in routing.snapshot()['sinks'].values():
                    if not process_alive(state.get('sender_process')):
                        raise RuntimeError('RTP sender exited before creating its sink')
                    from common import remaining
                    remaining(1)
                    time.sleep(0.05)
                routing.route(state, JOURNAL)
                while self.receiver.get('state') != 'readyMuted':
                    if self.receiver.get('state') in ('recoveringMuted', 'recoveryPending', 'idle'):
                        raise RuntimeError(self.receiver.get('error') or 'Receiver startup was interrupted')
                    from common import remaining
                    remaining(1)
                    time.sleep(0.05)
                self.start_complete = True
                self.state = 'readyMuted'
                self.error = None
        except Exception as error:
            self.error = self.error or str(error)
            self.stop()

    def mute(self):
        self.mute_serial += 1
        serial = self.mute_serial
        self.mute_pending = True
        self.mute_uncertain = False
        self.mute_requested = time.monotonic()
        try:
            if not self.priority:
                raise RuntimeError('Receiver mute channel is not ready')
            response = self.priority.request({'version': VERSION, 'action': 'mute', 'session': self.session}, timeout=0.8)
            if response.get('muted') is not True:
                raise RuntimeError('Mute unconfirmed; audio worker termination has been requested')
            self.receiver = response
            if serial == self.mute_serial:
                self.mute_pending = False
                self.mute_uncertain = False
        except Exception as error:
            self.error = self.error or str(error)
            self.mute_uncertain = True
            if self.priority:
                self.priority.close()
                self.priority = None
        return self.status()

    def stop(self, confirm=False):
        if not self.stop_lock.acquire(blocking=False):
            return self.status()
        try:
            return self._stop(confirm)
        finally:
            self.stop_lock.release()

    def _stop(self, confirm=False):
        self.cancel.set()
        self.state = 'stopping'
        self.start_complete = False
        if self.priority:
            self.mute()
        if self.channel:
            self.channel.close()
            self.channel = None
        with self.lifecycle:
            try:
                cleanup(self.pairing, confirm=confirm)
                restored_state = 'idle'
                self.session = None
                self.receiver = {}
                self.mute_pending = self.mute_uncertain = False
                self.cancel.clear()
            except Exception as error:
                restored_state = 'recoveryPending'
                self.error = str(error)
            finally:
                if self.priority:
                    self.priority.close()
                    self.priority = None
                if self.guardian:
                    self.guardian.stdin.close()
                    self.guardian = None
                self.owner = None
                self.state = restored_state
        return self.status()

    def watch_owner(self):
        while not self.exiting.wait(0.05):
            now = time.monotonic()
            if self.owner and (not process_alive(self.owner) or now - self.app_heartbeat >= 3):
                self.owner = None
                threading.Thread(target=self.stop, daemon=True).start()
            if self.mute_pending and now - self.mute_requested >= 1:
                self.mute_uncertain = True

    def monitor(self):
        next_heartbeat = 0
        while not self.exiting.wait(0.05):
            now = time.monotonic()
            if now < next_heartbeat:
                continue
            next_heartbeat = now + 1
            channel = self.channel
            if not channel:
                if (self.owner and self.endpoint and self.last_control is not None
                        and self.state not in ('stopping', 'recoveryPending', 'idle')):
                    if now - self.last_control >= 12:
                        self.error = 'Control lease expired; restore and explicitly start again'
                        threading.Thread(target=self.stop, daemon=True).start()
                    else:
                        self.channel = Channel(self.pairing, self.endpoint)
                continue
            try:
                response = channel.request({'version': VERSION, 'action': 'heartbeat', 'session': self.session}, timeout=0.8)
                if channel is not self.channel or response.get('session') != self.session:
                    continue
                if response.get('version') != VERSION:
                    self.error = 'Protocol major mismatch during playback'
                    threading.Thread(target=self.stop, daemon=True).start()
                    continue
                if response.get('generation', -1) < self.receiver.get('generation', -1):
                    continue
                if not self.mute_pending and not self.mute_uncertain:
                    self.receiver = response
                elif response.get('generation', -1) >= self.receiver.get('generation', -1):
                    self.receiver = dict(response, muted=None)
                self.last_control = now
                if self.priority is None and self.owner and self.state not in ('stopping', 'recoveryPending', 'idle'):
                    self.priority = Channel(self.pairing, self.endpoint, priority=True)
                    if self.mute_pending:
                        threading.Thread(target=self.mute, daemon=True).start()
                self.logger.info(json.dumps({key: value for key, value in self.status().items() if key != 'preferences'}))
                if response.get('state') == 'recoveryPending':
                    self.error = response.get('error') or 'Receiver requires a fresh start'
                    threading.Thread(target=self.stop, daemon=True).start()
                    continue
                state = read_json(JOURNAL, {})
                if state.get('sender_process') and not process_alive(state['sender_process']):
                    self.error = 'RTP sender exited; explicit start is required'
                    threading.Thread(target=self.stop, daemon=True).start()
            except Exception as error:
                if self.channel is channel:
                    self.error = self.error or str(error)
                    self.logger.error('Receiver control failed: %s', error)
                    self.mute_uncertain = True
                    channel.close()
                    self.channel = None
                    if self.start_complete:
                        self.state = 'recoveringMuted'
                        self.receiver = dict(self.receiver, state='recoveringMuted', muted=None)
                    threading.Thread(target=self.mute, daemon=True).start()

    def request(self, request):
        try:
            validate_version(request)
        except ValueError:
            if self.owner:
                threading.Thread(target=self.stop, daemon=True).start()
            raise
        action = request.get('action')
        if action == 'diagnostics':
            report = self.status()
            report.pop('preferences', None)
            try:
                with deadline(5):
                    report['desktop_gains'] = routing.gains()
                    report['desktop_routing'] = routing.snapshot()
            except Exception as error:
                report['diagnostic_error'] = str(error)
            self.logger.info(json.dumps(report))
            return report
        if action == 'status':
            return self.status()
        if action == 'app-heartbeat':
            if self.owner and request.get('app_pid') == self.owner[0]:
                self.app_heartbeat = time.monotonic()
            return self.status()
        if action in ('stop', 'recover', 'close', 'drain'):
            if action == 'close' and (not self.owner or request.get('app_pid') != self.owner[0]):
                return self.status()
            if action == 'drain' and not DISABLED.exists():
                atomic_json(ROOT / 'disabled', {'maintenance': True})
            self.cancel.set()
            self.state = 'stopping'
            if action == 'drain':
                with deadline(60):
                    result = self.stop()
                    while result['state'] == 'stopping':
                        from common import remaining
                        remaining(1)
                        time.sleep(0.05)
                        result = self.stop()
                if result['state'] != 'idle':
                    raise RuntimeError('Package action aborted: ' + str(self.error))
                return result
            threading.Thread(target=self.stop, kwargs={'confirm': request.get('confirm_snapclient_restore') is True}, daemon=True).start()
            return self.status()
        if action == 'mute':
            return self.mute()
        if action in ('volume', 'unmute', 'standby'):
            if not self.start_complete or self.mute_pending or self.mute_uncertain or self.state in ('stopping', 'recoveryPending'):
                raise ValueError('Wait for confirmed receiver readiness before adjusting playback')
            if request.get('session') != self.session or request.get('generation') != self.receiver.get('generation'):
                raise ValueError('Stale session or recovery generation; confirm again')
            serial = self.mute_serial
            response = self.pairing.request(self.endpoint, request)
            if serial != self.mute_serial:
                raise ValueError('Mute invalidated this gain request')
            self.receiver = response
            return self.status()
        if action == 'start':
            with self.start_lock:
                if self.state != 'idle' or JOURNAL.exists() or self.stop_lock.locked():
                    raise ValueError('Stop and reconcile the previous session before starting')
                if not self.pairing.preferences()['opt_in']:
                    raise ValueError('Enable the RTP opt in preference first')
                owner = process_identity(request.get('app_pid', 0))
                if not owner or Path(f'/proc/{owner[0]}').stat().st_uid != os.getuid():
                    raise ValueError('The app must own the live process heartbeat')
                self.owner = owner
                self.session = uuid.uuid4().hex
                self.app_heartbeat = time.monotonic()
                self.state = 'preparing'
                self.error = None
                self.receiver = {}
                self.endpoint = None
                self.last_control = None
                self.cancel.clear()
                threading.Thread(target=self.start, args=(request,), daemon=True).start()
                return self.status()
        if action in ('pair-discover', 'pair-probe', 'pair', 'opt-in', 'preflight'):
            with self.lifecycle, deadline(30):
                if self.state != 'idle' or JOURNAL.exists():
                    raise ValueError('Stop and reconcile before changing pairing or preferences')
                if action == 'pair-discover':
                    return dict(self.pairing.discover(request), version=VERSION)
                if action == 'pair-probe':
                    return dict(self.pairing.probe(request), version=VERSION)
                if action == 'pair':
                    return dict(self.pairing.confirm(request), version=VERSION)
                if action == 'opt-in':
                    return dict(self.pairing.opt_in(request['enabled']), version=VERSION)
                return self.preflight()
        raise ValueError('Unknown laptop audio operation')

    def serve(self):
        socket_path = RUNTIME / 'control.sock'
        socket_path.unlink(missing_ok=True)
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(socket_path))
            os.chmod(socket_path, 0o600)
            listener.listen(16)
            listener.settimeout(0.2)

            def handle(connection):
                with connection:
                    connection.settimeout(65)
                    request = {}
                    try:
                        process_id, user_id, group_id = peer_credentials(connection)
                        if user_id != os.getuid():
                            raise PermissionError('Only the owning desktop user can control RTP')
                        request = receive(connection)
                        response = self.request(request)
                    except Exception as error:
                        response = {'version': VERSION, 'error': str(error)}
                    try:
                        send(connection, response)
                    except OSError:
                        pass
                    finally:
                        if request.get('action') == 'drain' and response.get('state') == 'idle':
                            self.exiting.set()

            while not self.exiting.is_set():
                try:
                    connection, address = listener.accept()
                    threading.Thread(target=handle, args=(connection,), daemon=True).start()
                except socket.timeout:
                    continue
        socket_path.unlink(missing_ok=True)


def main():
    RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
    if len(sys.argv) > 1 and sys.argv[1] == '_guard':
        sender = None
        expected_session = sys.argv[2]
        try:
            for line in sys.stdin:
                if json.loads(line).get('action') != 'sender' or sender:
                    raise ValueError('Invalid guardian operation')
                state = read_json(JOURNAL)
                if state['session'] != expected_session:
                    raise ValueError('Guardian no longer owns this session')
                sender = subprocess.Popen(['pipewire', '-c', str(ROOT / 'sender.conf')],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                state['sender_process'] = process_identity(sender.pid)
                atomic_json(JOURNAL, state)
                print(json.dumps({'started': True}), flush=True)
        finally:
            try:
                cleanup(Pairing(CONFIG), expected_session=expected_session)
            finally:
                if sender:
                    routing.stop_process(process_identity(sender.pid))
                    sender.wait(timeout=1)
        return
    if len(sys.argv) > 1 and sys.argv[1] == '_daemon':
        with (RUNTIME / 'daemon.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            controller = Controller()
            for signum in (signal.SIGINT, signal.SIGTERM):
                signal.signal(signum, lambda received, frame: controller.exiting.set())
            try:
                controller.serve()
            finally:
                controller.stop()
        return
    request = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {'version': VERSION, 'action': 'status'}
    socket_path = RUNTIME / 'control.sock'
    try:
        response = exchange(socket_path, request, timeout=65, check=False)
    except (FileNotFoundError, ConnectionRefusedError, EOFError, ConnectionResetError) as error:
        if isinstance(error, (EOFError, ConnectionResetError)) and request.get('action') != 'drain':
            raise
        subprocess.Popen([sys.executable, str(DIRECTORY / 'laptop.py'), '_daemon'],
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, start_new_session=True)
        expires = time.monotonic() + 3
        while True:
            try:
                response = exchange(socket_path, request, timeout=65, check=False)
                break
            except (FileNotFoundError, ConnectionRefusedError, EOFError, ConnectionResetError) as error:
                if isinstance(error, (EOFError, ConnectionResetError)) and request.get('action') != 'drain':
                    raise
                if time.monotonic() > expires:
                    raise RuntimeError('Laptop controller did not start; inspect pending recovery journals')
                if isinstance(error, (FileNotFoundError, ConnectionRefusedError)):
                    subprocess.Popen([sys.executable, str(DIRECTORY / 'laptop.py'), '_daemon'],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, start_new_session=True)
                time.sleep(0.05)
    print(json.dumps(response))
    if response.get('error') and 'state' not in response:
        sys.exit(1)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'version': VERSION, 'error': str(error)}))
        sys.exit(1)
