"""Pin a user verified SSH key and resolve addresses per session."""

import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import select
import shlex
import socket
import subprocess
import threading
import time
import uuid

from common import VERSION, atomic_json, read_json, remaining, run


REMOTE = '/usr/lib/syren-rtp/receiver.py'


class Pairing:
    def __init__(self, directory):
        self.directory = directory
        self.path = directory / 'preferences.json'
        self.known_hosts = directory / 'known_hosts'
        self.candidate_path = directory / 'pairing-pending.json'

    def preferences(self):
        return read_json(self.path, {'opt_in': False, 'pairing': None})

    def opt_in(self, enabled):
        if type(enabled) is not bool:
            raise ValueError('Opt in must be a boolean')
        atomic_json(self.path, dict(self.preferences(), opt_in=enabled))
        return self.preferences()

    def resolve(self, host):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', host):
            raise ValueError('Enter an SSH hostname or IPv4 address without a user or command')
        addresses = run(['getent', 'ahostsv4', host], timeout=4).stdout.splitlines()
        if not addresses:
            raise ValueError('SSH host has no IPv4 address')
        return str(ipaddress.IPv4Address(addresses[0].split()[0]))

    def discover(self, request):
        for field in ('snapclient_id', 'name'):
            if not isinstance(request.get(field), str) or not 1 <= len(request[field]) <= 256:
                raise ValueError('Select a discovered Snapclient identity and name')
        previous = self.preferences().get('pairing')
        if previous and previous['snapclient_id'] == request['snapclient_id']:
            return {**{field: previous[field] for field in ('host', 'user', 'port', 'key')},
                    'message': 'Using the saved connection details for this receiver.'}
        defaults = {'host': '', 'user': pwd.getpwuid(os.getuid()).pw_name, 'port': 22, 'key': '',
                    'message': 'The suggested user is your laptop login. Change it if the receiver uses another account.'}
        hostname = request['name'].strip()
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', hostname):
            candidates = [hostname] if '.' in hostname else [hostname + '.local', hostname]
            for candidate in candidates:
                try:
                    address = self.resolve(candidate)
                except (ValueError, RuntimeError, OSError, TimeoutError, subprocess.SubprocessError):
                    continue
                defaults.update(host=candidate, address=address)
                return defaults
        defaults['message'] = 'The receiver was discovered, but its hostname could not be resolved. Enter its SSH address. The suggested user is your laptop login.'
        return defaults

    def probe(self, request):
        host, user = request['host'].strip(), request['user'].strip()
        if not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_-]{0,63}', user):
            raise ValueError('Enter an SSH user name')
        port = request.get('port', 22)
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError('SSH port must be between 1 and 65535')
        key = request.get('key', '').strip()
        if key and (not Path(key).is_absolute() or not Path(key).is_file()):
            raise ValueError('Select an existing absolute SSH private key path, or leave empty for the SSH agent')
        for field in ('snapclient_id', 'name'):
            if not isinstance(request.get(field), str) or not 1 <= len(request[field]) <= 256:
                raise ValueError('Select a discovered Snapclient identity and name')
        address = self.resolve(host)
        scanned = run(['ssh-keyscan', '-T', '3', '-p', str(port), '-t', 'ed25519', address], timeout=4).stdout
        lines = [line.split() for line in scanned.splitlines() if not line.startswith('#')]
        if not lines or len(lines[0]) != 3 or lines[0][1] != 'ssh-ed25519':
            raise RuntimeError('Receiver has no Ed25519 host key; enable one in a terminal')
        alias = 'syren-' + hashlib.sha256(f'{host}:{port}'.encode()).hexdigest()[:24]
        key_line = f'{alias} {lines[0][1]} {lines[0][2]}\n'
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        candidate_key = self.directory / 'candidate_host_key'
        candidate_key.write_text(key_line)
        try:
            fingerprint = run(['ssh-keygen', '-lf', str(candidate_key), '-E', 'sha256']).stdout.split()[1]
        finally:
            candidate_key.unlink(missing_ok=True)
        previous = self.preferences().get('pairing')
        changed = bool(previous and previous['host'] == host and previous['fingerprint'] != fingerprint)
        candidate = {'host': host, 'user': user, 'port': port, 'key': key, 'alias': alias,
                     'snapclient_id': request['snapclient_id'], 'name': request['name'],
                     'fingerprint': fingerprint, 'key_line': key_line, 'address': address,
                     'challenge': uuid.uuid4().hex, 'expires': time.time() + 300, 'changed_key': changed}
        atomic_json(self.candidate_path, candidate)
        return {key: value for key, value in candidate.items() if key != 'key_line'}

    def confirm(self, request):
        candidate = read_json(self.candidate_path)
        if (not candidate or candidate['expires'] < time.time()
                or request.get('challenge') != candidate['challenge']
                or request.get('verified_fingerprint') != candidate['fingerprint']):
            raise ValueError('Verify the current fingerprint against the receiver terminal before pairing')
        if candidate['changed_key'] and request.get('repair_changed_key') is not True:
            raise ValueError('Changed host key blocks operation; explicit re-pairing is required')
        pairing = {key: value for key, value in candidate.items()
                   if key not in ('challenge', 'expires', 'changed_key', 'key_line')}
        temporary = self.known_hosts.with_suffix('.tmp')
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            output.write(candidate['key_line'])
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(self.known_hosts)
        atomic_json(self.path, dict(self.preferences(), pairing=pairing))
        self.candidate_path.unlink()
        return self.preferences()

    def endpoint(self):
        pairing = self.preferences().get('pairing')
        if not pairing or not self.known_hosts.exists():
            raise ValueError('Pair a discovered speaker and verify its SSH host key first')
        address = self.resolve(pairing['host'])
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect((address, 46000))
            sender_address = probe.getsockname()[0]
        return dict(pairing, address=address, sender_address=sender_address)

    def arguments(self, endpoint, command):
        arguments = ['ssh', '-F', '/dev/null', '-T', '-o', 'BatchMode=yes',
                     '-o', 'StrictHostKeyChecking=yes', '-o', 'UpdateHostKeys=no',
                     '-o', 'GlobalKnownHostsFile=/dev/null', '-o', f'UserKnownHostsFile={self.known_hosts}',
                     '-o', f'HostKeyAlias={endpoint["alias"]}', '-o', 'ConnectTimeout=3',
                     '-o', 'ServerAliveInterval=1', '-o', 'ServerAliveCountMax=2',
                     '-o', 'ClearAllForwardings=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                     '-p', str(endpoint['port']), '-l', endpoint['user']]
        if endpoint.get('key'):
            arguments.extend(['-o', 'IdentitiesOnly=yes', '-i', endpoint['key']])
        return arguments + [endpoint['address'], shlex.join(command)]

    def request(self, endpoint, payload, timeout=8):
        try:
            result = run(self.arguments(endpoint, [REMOTE, 'request', '--payload', json.dumps(payload)]),
                         timeout=timeout, check=False)
        except (TimeoutError, OSError) as error:
            raise RuntimeError('SSH did not respond within its deadline; check the connection in a terminal') from error
        if result.returncode == 255:
            raise RuntimeError('SSH access failed. Verify the pinned host key, unlock your SSH agent or selected key in a terminal, and check access. Changed keys require explicit re-pairing.')
        try:
            response = json.loads(result.stdout)
        except ValueError as error:
            raise RuntimeError('Receiver package is unavailable; install syren-rtp-receiver using sudo in a visible terminal') from error
        if response.get('error') or result.returncode:
            raise RuntimeError(response.get('error', 'Receiver command failed'))
        return response


class Channel:
    def __init__(self, pairing, endpoint, priority=False):
        self.process = subprocess.Popen(pairing.arguments(endpoint, [REMOTE, 'priority' if priority else 'channel']),
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.lock = threading.Lock()

    def request(self, payload, timeout=2):
        if not self.lock.acquire(timeout=min(timeout, 0.1)):
            raise TimeoutError('Receiver channel is busy; mute remains unconfirmed')
        try:
            self.process.stdin.write(json.dumps(payload) + '\n')
            self.process.stdin.flush()
            if not select.select([self.process.stdout], [], [], remaining(timeout))[0]:
                self.close()
                raise TimeoutError('Authenticated receiver channel timed out')
            response = json.loads(self.process.stdout.readline())
            if response.get('error') and 'state' not in response:
                raise RuntimeError(response['error'])
            return response
        finally:
            self.lock.release()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=0.1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=0.2)
