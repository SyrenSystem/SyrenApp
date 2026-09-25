#!/usr/bin/python3
"""Broker fixed receiver operations through a local control socket."""

import argparse
import grp
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import signal
import shlex
import socket
import sys
import threading
import time

from common import (VERSION, atomic_json, deadline, exchange, peer_credentials, read_json,
                    receive, remove_journal, run, send, validate_version)
from compatibility import probe


CONFIGURATION = Path('/etc/syrensystem/receiver.json')
STATE = Path('/var/lib/syren-rtp/state.json')
RUNTIME = Path('/run/syren-rtp')
SOCKET = Path('/run/syren-rtp-broker.sock')
AUDIO_SERVICE = 'syren-rtp-audio.service'
SNAP_SERVICE = 'snapclient.service'
DISABLED = Path('/var/lib/syren-rtp/disabled')


def snapcast_settings(configuration, defaults=Path('/etc/default/snapclient')):
    host = configuration.get('snapserver_host')
    port = configuration.get('snapserver_port', 1704)
    if not host and defaults.exists():
        for line in defaults.read_text().splitlines():
            if not line.strip().startswith('SNAPCLIENT_OPTS='):
                continue
            values = shlex.split(line.split('=', 1)[1])
            arguments = shlex.split(values[0]) if len(values) == 1 else values
            for index, argument in enumerate(arguments[:-1]):
                if argument in ('-h', '--host'):
                    host = arguments[index + 1]
                if argument in ('-p', '--port'):
                    port = int(arguments[index + 1])
    if not isinstance(host, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.:-]{0,252}', host):
        raise ValueError('Configure the Snapserver host with syren-rtp-configure --snapserver-host')
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('Invalid configured Snapserver port')
    return {'host': host, 'port': port, 'id': configuration['snapclient_id']}


def service_state(service):
    result = run(['systemctl', 'show', service, '-p', 'ActiveState', '-p', 'InvocationID',
                  '-p', 'InactiveEnterTimestampMonotonic'])
    state = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    state['boot_id'] = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    return state


def stop_audio():
    run(['systemctl', 'stop', '--no-block', AUDIO_SERVICE])
    expires = time.monotonic() + 2
    while time.monotonic() < expires:
        if service_state(AUDIO_SERVICE)['ActiveState'] in ('inactive', 'failed'):
            return
        time.sleep(0.05)
    run(['systemctl', 'kill', '--signal=SIGKILL', '--kill-whom=all', AUDIO_SERVICE], check=False)
    expires = time.monotonic() + 2
    while time.monotonic() < expires:
        if service_state(AUDIO_SERVICE)['ActiveState'] in ('inactive', 'failed'):
            return
        time.sleep(0.05)
    raise RuntimeError('Audio cgroup did not stop; restoration remains pending')


def restore(confirm=False):
    state = read_json(STATE)
    if not state:
        return
    stop_audio()
    if state.get('snap_stop_intended'):
        current = service_state(SNAP_SERVICE)
        if current['ActiveState'] != 'active':
            if not confirm and current != state.get('snap_stopped'):
                raise RuntimeError('Snapclient ownership is ambiguous; inspect service history and use explicit recovery confirmation')
            atomic_json(STATE, dict(state, snap_restore_intended=True))
            run(['systemctl', 'start', SNAP_SERVICE], timeout=20)
            if service_state(SNAP_SERVICE)['ActiveState'] != 'active':
                raise RuntimeError('Snapclient restoration is pending')
    atomic_json(STATE.with_name('last-state.json'), dict(state, restored_at=time.time()))
    remove_journal(STATE)


class Broker:
    def __init__(self):
        self.configuration = read_json(CONFIGURATION)
        if not self.configuration:
            raise RuntimeError('Install receiver.json with a selected interface and Snapclient identity')
        self.lock = threading.Lock()
        self.cancel = threading.Event()
        self.error = None
        self.stopping = threading.Event()
        with deadline(60):
            try:
                restore()
            except Exception as error:
                self.error = str(error)

    def allowed(self, user_id):
        if user_id == 0:
            return True
        account = pwd.getpwuid(user_id)
        control_group = grp.getgrnam(self.configuration['control_group']).gr_gid
        return control_group in os.getgrouplist(account.pw_name, account.pw_gid)

    def worker(self, request, timeout=3):
        name = 'mute.sock' if request['action'] == 'mute' else 'control.sock'
        return exchange(Path('/run/syren-rtp-audio') / name, request, timeout=timeout)

    def preflight(self):
        report = probe(receiver=True)
        address = str(ipaddress.IPv4Address(self.configuration['bind_address']))
        if address == '0.0.0.0':
            report['errors'].append('Select the receiving interface address in receiver.json')
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
                connection.bind((address, 46000))
        except OSError as error:
            report['errors'].append('Receiver interface or UDP port unavailable: ' + str(error))
        device = self.configuration['device']
        hardware = self.configuration['hardware_path']
        if not re.fullmatch(r'hw:[A-Za-z0-9_]+,[0-9]+', device):
            report['errors'].append('Invalid fixed ALSA device in receiver.json')
        if not re.fullmatch(r'/proc/asound/[A-Za-z0-9_]+/pcm[0-9]+p/sub[0-9]+/hw_params', hardware):
            report['errors'].append('Invalid ALSA parameter path in receiver.json')
        if not Path(hardware).exists():
            report['errors'].append('Configured ALSA playback device is absent')
        report['device'] = {'path': device, 'present': Path(hardware).exists(),
                            'negotiation': 'checked muted after ownership, 48 kHz stereo S32_LE, 128 or 256 frames, three periods'}
        report['snapclient_id'] = self.configuration['snapclient_id']
        report['bind_address'] = address
        report['protocol'] = VERSION
        report['shared_output'] = True
        try:
            report['snapcast'] = snapcast_settings(self.configuration)
        except ValueError as error:
            report['errors'].append(str(error))
        if DISABLED.exists():
            report['errors'].append('Package maintenance has disabled new starts')
        if STATE.exists():
            report['errors'].append('Receiver recovery is pending; reconcile before starting')
        report['ready'] = not report['errors']
        return dict(report, version=VERSION)

    def dispatch(self, request, user_id):
        action = request.get('action')
        state = read_json(STATE)
        if action == 'worker-failed':
            if user_id not in (0, pwd.getpwnam('syren-rtp').pw_uid):
                raise PermissionError('Only the audio service may escalate worker failure')
            if state and request.get('session') == state['session']:
                self.cancel.set()
                run(['systemctl', 'kill', '--signal=SIGKILL', '--kill-whom=all', AUDIO_SERVICE], check=False, timeout=0.2)
                threading.Thread(target=self.cleanup, args=(state['session'],), daemon=True).start()
            return {'version': VERSION, 'stopping': True}
        if user_id == pwd.getpwnam('syren-rtp').pw_uid:
            raise PermissionError('The audio account may only report worker failure')
        if not self.allowed(user_id):
            raise PermissionError('Join the installation selected receiver control group in a terminal')
        if state and action not in ('preflight', 'status'):
            if user_id not in (0, state['owner_uid']) or request.get('session') != state['session']:
                raise PermissionError('This session does not own the receiver')
        try:
            validate_version(request)
        except ValueError:
            if state and request.get('session') == state['session']:
                self.cancel.set()
                self.safety_mute(state)
                threading.Thread(target=self.cleanup, args=(state['session'],), daemon=True).start()
            raise
        if action == 'preflight':
            return self.preflight()
        if action == 'start':
            with self.lock, deadline(60, self.cancel):
                report = self.preflight()
                if not report['ready']:
                    raise RuntimeError('; '.join(report['errors']))
                if request.get('snapclient_id') != self.configuration['snapclient_id']:
                    raise ValueError('Paired Snapclient identity does not match receiver installation')
                session = request.get('session', '')
                if not re.fullmatch('[a-f0-9]{32}', session):
                    raise ValueError('Invalid session identifier')
                sender_address = str(ipaddress.IPv4Address(request['sender_address']))
                if request.get('latency', 20) not in (10, 15, 20, 30, 40):
                    raise ValueError('Unsupported target latency')
                previous = service_state(SNAP_SERVICE)
                if previous['ActiveState'] not in ('active', 'inactive', 'failed'):
                    raise RuntimeError('Snapclient is changing state; retry after it settles')
                state = {'session': session, 'owner_uid': user_id, 'snap_before': previous,
                         'snap_stop_intended': previous['ActiveState'] == 'active'}
                atomic_json(STATE, state)
                try:
                    if state['snap_stop_intended']:
                        run(['systemctl', 'stop', SNAP_SERVICE], timeout=20)
                        state['snap_stopped'] = service_state(SNAP_SERVICE)
                        if state['snap_stopped']['ActiveState'] not in ('inactive', 'failed'):
                            raise RuntimeError('Snapclient has not released ALSA')
                        atomic_json(STATE, state)
                    configuration = dict(self.configuration, snapcast=snapcast_settings(self.configuration), session=session, sender_address=sender_address,
                                         latency=request.get('latency', 20))
                    atomic_json(RUNTIME / 'session.json', configuration)
                    account = pwd.getpwnam('syren-rtp')
                    os.chown(RUNTIME / 'session.json', 0, account.pw_gid)
                    os.chmod(RUNTIME / 'session.json', 0o640)
                    state['audio_start_intended'] = True
                    atomic_json(STATE, state)
                    run(['systemctl', 'start', AUDIO_SERVICE])
                    return {'version': VERSION, 'state': 'preparing', 'session': session}
                except Exception:
                    threading.Thread(target=self.cleanup, args=(state['session'],), daemon=True).start()
                    raise
        if action in ('stop', 'recover', 'drain'):
            if action == 'drain':
                DISABLED.parent.mkdir(parents=True, exist_ok=True)
                DISABLED.touch(mode=0o600)
            self.cancel.set()
            if state:
                self.safety_mute(state)
            with self.lock, deadline(60):
                restore(confirm=request.get('confirm_snapclient_restore') is True and action == 'recover')
            self.error = None
            self.cancel.clear()
            return {'version': VERSION, 'state': 'idle', 'restored': True}
        if not state:
            if action == 'status':
                return {'version': VERSION, 'state': 'idle', 'restored': True, 'error': self.error}
            raise RuntimeError('No receiver session is active')
        if action == 'status':
            if request.get('session') not in (None, state['session']):
                raise ValueError('A different session owns the receiver')
            request = dict(request, session=state['session'])
        if action not in ('status', 'heartbeat', 'mute', 'volume', 'unmute', 'standby', 'disconnect', 'diagnostics'):
            raise ValueError('Unknown fixed receiver operation')
        try:
            return self.worker(request, timeout=0.5 if action == 'mute' else 3)
        except Exception as error:
            if action in ('mute', 'disconnect'):
                self.cancel.set()
                run(['systemctl', 'kill', '--signal=SIGKILL', '--kill-whom=all', AUDIO_SERVICE], check=False)
                threading.Thread(target=self.cleanup, args=(state['session'],), daemon=True).start()
            if action == 'status':
                return {'version': VERSION, 'state': 'recoveryPending', 'session': state['session'],
                        'muted': None, 'error': self.error or str(error)}
            raise

    def safety_mute(self, state):
        try:
            self.worker({'version': VERSION, 'action': 'mute', 'session': state['session']}, timeout=0.5)
        except Exception:
            run(['systemctl', 'kill', '--signal=SIGKILL', '--kill-whom=all', AUDIO_SERVICE], check=False)

    def cleanup(self, expected_session):
        with self.lock, deadline(60):
            state = read_json(STATE)
            if not state or state['session'] != expected_session:
                return
            self.cancel.set()
            try:
                restore()
                self.error = None
                self.cancel.clear()
            except Exception as error:
                self.error = str(error)

    def serve(self):
        if int(os.environ.get('LISTEN_FDS', '0')) != 1:
            raise RuntimeError('The broker requires its systemd socket')
        listener = socket.socket(fileno=3)
        listener.settimeout(0.2)

        def handle(connection):
            with connection:
                connection.settimeout(65)
                try:
                    process_id, user_id, group_id = peer_credentials(connection)
                    result = self.dispatch(receive(connection), user_id)
                except Exception as error:
                    result = {'version': VERSION, 'error': str(error)}
                try:
                    send(connection, result)
                except OSError:
                    pass

        while not self.stopping.is_set():
            try:
                connection, address = listener.accept()
                threading.Thread(target=handle, args=(connection,), daemon=True).start()
            except socket.timeout:
                continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['broker', 'request', 'channel', 'priority', 'control', 'restore', 'worker-exit', 'drain'])
    parser.add_argument('--payload', default='{}')
    arguments = parser.parse_args()
    if arguments.action == 'broker':
        broker = Broker()
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda received, frame: broker.stopping.set())
        broker.serve()
    elif arguments.action == 'restore':
        with deadline(60):
            restore()
    elif arguments.action == 'worker-exit':
        state = read_json(STATE)
        if state:
            exchange(SOCKET, {'version': VERSION, 'action': 'worker-failed', 'session': state['session']})
    elif arguments.action == 'drain':
        DISABLED.parent.mkdir(parents=True, exist_ok=True)
        DISABLED.touch(mode=0o600)
        state = read_json(STATE, {})
        if not SOCKET.exists():
            if os.geteuid() != 0:
                raise PermissionError('Receiver maintenance requires root')
            with deadline(60):
                stop_audio()
                restore()
            print(json.dumps({'version': VERSION, 'state': 'idle', 'restored': True}))
            return
        if not state and not CONFIGURATION.exists():
            print(json.dumps({'version': VERSION, 'state': 'idle', 'restored': True}))
            return
        print(json.dumps(exchange(SOCKET, {'version': VERSION, 'action': 'drain',
                                         'session': state.get('session')}, timeout=65)))
    elif arguments.action == 'request':
        print(json.dumps(exchange(SOCKET, json.loads(arguments.payload), timeout=65)))
    else:
        session = None
        try:
            for line in sys.stdin:
                request = json.loads(line)
                allowed = {'priority': ('mute',), 'channel': ('heartbeat',),
                           'control': ('volume', 'unmute', 'standby')}[arguments.action]
                if request.get('action') not in allowed:
                    raise ValueError('Operation is not allowed on this channel')
                response = exchange(SOCKET, request)
                session = request['session']
                print(json.dumps(response), flush=True)
        finally:
            if session and arguments.action == 'channel':
                try:
                    exchange(SOCKET, {'version': VERSION, 'action': 'disconnect', 'session': session}, timeout=1)
                except Exception:
                    pass


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'version': VERSION, 'error': str(error)}), flush=True)
        sys.exit(1)
