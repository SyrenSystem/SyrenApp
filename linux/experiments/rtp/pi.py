#!/usr/bin/python3
"""Run the isolated receiver and restore Snapclient when it ends."""

import argparse
import fcntl
import glob
import json
import logging
import logging.handlers
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time


INSTALL = Path(__file__).resolve().parent
RUNTIME = Path('/run/syren-rtp')
ROOT_STATE = Path('/var/lib/syren-rtp/state.json')
LEASE_SECONDS = 12
stopping = False


def run(arguments, check=True, timeout=10, **options):
    return subprocess.run(arguments, text=True, capture_output=True, check=check,
                          timeout=timeout, **options)


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as output:
        json.dump(value, output, indent=2)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def stop_signal(signum, frame):
    global stopping
    stopping = True


def snap_state():
    return run(['systemctl', 'show', 'snapclient.service', '-p', 'ActiveState',
                '--value']).stdout.strip()


def restore():
    if not ROOT_STATE.exists():
        return
    state = json.loads(ROOT_STATE.read_text())
    if state.get('snap_changed') and state['snap_active'] and snap_state() != 'active':
        run(['systemctl', 'start', 'snapclient.service'], timeout=30)
        if snap_state() != 'active':
            raise RuntimeError('Snapclient did not become active; recovery state retained')
    state['restored_at'] = time.time()
    atomic_json(ROOT_STATE.with_name('last-state.json'), state)
    ROOT_STATE.unlink()


def launch(arguments):
    username = os.environ.get('SUDO_USER', '')
    if not username or username == 'root':
        raise RuntimeError('Launch with interactive sudo from the audio user')
    account = pwd.getpwnam(username)
    command = [
        'systemd-run', '--unit=syren-rtp.service', '--collect', '--wait',
        '--property=Restart=no', '--property=KillMode=control-group',
        '--property=TimeoutStopSec=45', '--property=LimitRTPRIO=88',
        '--property=LimitNICE=31', '--property=LimitMEMLOCK=268435456',
        f'--property=ExecStopPost={INSTALL}/pi.py restore',
        str(INSTALL / 'pi.py'), 'supervise', '--user', account.pw_name,
        '--session', arguments.session, '--latency', str(arguments.latency),
    ]
    return subprocess.call(command)


def supervise(arguments):
    account = pwd.getpwnam(arguments.user)
    with open('/run/syren-rtp.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        restore()
        RUNTIME.mkdir(mode=0o755, exist_ok=True)
        directory = RUNTIME / arguments.session
        directory.mkdir(mode=0o700)
        os.chown(directory, account.pw_uid, account.pw_gid)
        ROOT_STATE.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        previous = snap_state()
        if previous not in ('active', 'inactive', 'failed'):
            raise RuntimeError(f'Snapclient is changing state: {previous}')
        state = {'session': arguments.session, 'snap_active': previous == 'active',
                 'snap_changed': previous == 'active', 'started_at': time.time()}
        atomic_json(ROOT_STATE, state)
        if state['snap_changed']:
            run(['systemctl', 'stop', 'snapclient.service'], timeout=30)
        child = subprocess.Popen([
            str(INSTALL / 'pi.py'),
            'worker', '--session', arguments.session, '--latency', str(arguments.latency),
        ], user=account.pw_uid, group=account.pw_gid,
            extra_groups=os.getgrouplist(account.pw_name, account.pw_gid),
            env=dict(os.environ, HOME=account.pw_dir, USER=account.pw_name, LOGNAME=account.pw_name))
        while child.poll() is None and not stopping:
            time.sleep(0.2)
        if stopping and child.poll() is None:
            child.terminate()
        try:
            return child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            return 1


def diagnostic(arguments, environment=None):
    try:
        result = run(arguments, check=False, timeout=5, env=environment)
        return {'command': arguments, 'returncode': result.returncode,
                'stdout': result.stdout, 'stderr': result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'command': arguments, 'error': str(error)}


def hw_parameters():
    return {path: Path(path).read_text() for path in
            glob.glob('/proc/asound/card*/pcm*p/sub*/hw_params')}


def collect(environment=None):
    return {
        'timestamp': time.time(), 'hw_params': hw_parameters(),
        'pcm_status': {path: Path(path).read_text() for path in
                       glob.glob('/proc/asound/card*/pcm*p/sub*/status')},
        'commands': [diagnostic(command, environment) for command in [
            ['pipewire', '--version'], ['pw-dump'], ['pw-link', '-l'],
            ['pw-top', '-b', '-n', '2'], ['pw-metadata', '-n', 'settings'],
            ['ss', '-u', '-a', '-n', '-m'], ['ip', '-s', 'link'],
            ['amixer', '-c', 'sndrpihifiberry', 'sget', 'Digital'],
        ]],
        'udp_counters': Path('/proc/net/snmp').read_text(),
    }


def check():
    missing = [name for name in ['pipewire', 'pw-cli', 'pw-dump', 'pw-link',
                                'pw-top', 'pw-metadata', 'aplay', 'amixer', 'ss']
               if not shutil.which(name)]
    modules = {name: glob.glob(f'/usr/lib/*/pipewire-0.3/{name}.so') for name in
               ['libpipewire-module-rtp-source', 'libpipewire-module-adapter']}
    alsa = glob.glob('/usr/lib/*/spa-0.2/alsa/libspa-alsa.so')
    access = {path: os.access(path, os.R_OK | os.W_OK) for path in
              glob.glob('/dev/snd/pcm*p')}
    port_free = False
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(('0.0.0.0', 46000))
            port_free = True
    except OSError:
        pass
    report = {'missing_commands': missing, 'modules': modules, 'alsa_module': alsa,
              'alsa_access': access, 'udp_46000_free': port_free,
              'snapclient': snap_state(),
              'version': diagnostic(['pipewire', '--version']),
              'devices': diagnostic(['aplay', '-l']),
              'mixer': diagnostic(['amixer', '-c', 'sndrpihifiberry', 'sget', 'Digital'])}
    report['ready'] = (not missing and all(modules.values()) and bool(alsa) and
                       bool(access) and all(access.values()) and port_free and
                       'libpipewire 1.4.2' in report['version'].get('stdout', '') and
                       'sndrpihifiberry' in report['devices'].get('stdout', ''))
    print(json.dumps(report, indent=2))
    return 0 if report['ready'] else 1


class Receiver:
    def __init__(self, directory, latency):
        self.directory = directory
        shutil.copyfile('/usr/share/pipewire/client.conf', directory / 'client.conf')
        self.latency = latency
        self.process = None
        self.output_id = None
        self.volume = 10
        self.muted = True
        self.period = None
        self.receiving = None
        self.missing_rtp_since = None
        self.environment = dict(os.environ, XDG_RUNTIME_DIR=str(directory),
                                PIPEWIRE_RUNTIME_DIR=str(directory),
                                PIPEWIRE_REMOTE='syren-rtp', PIPEWIRE_DEBUG='3',
                                PIPEWIRE_CONFIG_DIR=str(directory))
        self.logger = logging.getLogger('receiver')
        self.logger.setLevel(logging.INFO)
        handler = logging.handlers.RotatingFileHandler(
            directory / 'pipewire.log', maxBytes=10 * 1024 * 1024, backupCount=3)
        self.logger.addHandler(handler)

    def command(self, *arguments):
        return run(list(arguments), env=self.environment)

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()

    def log_output(self, process):
        for line in process.stdout:
            self.logger.info(line.rstrip())

    def set_volume(self, volume, muted):
        if not isinstance(volume, int) or isinstance(volume, bool) or not 0 <= volume <= 100:
            raise ValueError('Volume must be an integer from 0 to 100')
        if not isinstance(muted, bool):
            raise ValueError('Mute must be a boolean')
        fraction = volume / 100
        self.command('pw-cli', 'set-param', str(self.output_id), 'Props',
                     f'{{ mute = {str(muted).lower()} channelVolumes = [ {fraction} {fraction} ] }}')
        objects = json.loads(self.command('pw-dump').stdout)
        output = next(item for item in objects if item['id'] == self.output_id)
        properties = output['info']['params']['Props'][0]
        if properties['mute'] != muted or any(abs(actual - fraction) > 0.00001 for actual in properties['channelVolumes']):
            raise RuntimeError('Receiver did not confirm software volume and mute')
        self.volume, self.muted = volume, muted

    def check_health(self, expect_rtp=False):
        hardware = Path('/proc/asound/sndrpihifiberry/pcm0p/sub0/hw_params').read_text()
        if f'period_size: {self.period}\n' not in hardware or 'rate: 48000 ' not in hardware:
            raise RuntimeError('HiFiBerry stopped using the negotiated audio format')
        objects = json.loads(self.command('pw-dump').stdout)
        nodes = [item['info'] for item in objects if item.get('info', {}).get('props', {}).get('node.name')
                 in ['syren_hifiberry', 'syren_rtp_receive']]
        if len(nodes) != 2 or any(node['state'] != 'running' for node in nodes):
            raise RuntimeError('Receiver audio graph stopped running')
        source = next(node for node in nodes if node['props']['node.name'] == 'syren_rtp_receive')
        self.receiving = source['props'].get('rtp.receiving') in [True, 'true']
        if self.receiving:
            self.missing_rtp_since = None
        elif expect_rtp and self.missing_rtp_since is None:
            self.missing_rtp_since = time.monotonic()
        elif expect_rtp and time.monotonic() - self.missing_rtp_since > 6:
            raise RuntimeError('RTP packets stopped arriving although the audio graph is running')

    def adjust(self, volume, muted):
        if not isinstance(volume, int) or isinstance(volume, bool) or not 0 <= volume <= 100:
            raise ValueError('Volume must be an integer from 0 to 100')
        if volume != 0 and abs(volume - self.volume) > 10:
            raise ValueError('Adjust by at most 10 percentage points per command')
        self.set_volume(volume, muted)

    def start(self):
        attempts = []
        for period in [128, 256]:
            configuration = (INSTALL / 'templates/receiver.conf.in').read_text()
            configuration = configuration.replace('@LATENCY@', str(self.latency))
            configuration = configuration.replace('@PERIOD@', str(period))
            configuration_path = self.directory / 'receiver.conf'
            configuration_path.write_text(configuration)
            self.process = subprocess.Popen(['pipewire', '-c', str(configuration_path)],
                                            env=self.environment, stdout=subprocess.PIPE,
                                            stderr=subprocess.STDOUT, text=True)
            threading.Thread(target=self.log_output, args=(self.process,), daemon=True).start()
            try:
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if self.process.poll() is not None:
                        raise RuntimeError('PipeWire exited before its graph was ready')
                    try:
                        objects = json.loads(self.command('pw-dump').stdout)
                        self.output_id = next(item['id'] for item in objects if
                                              item.get('info', {}).get('props', {}).get('node.name')
                                              == 'syren_hifiberry')
                        ports = self.command('pw-link', '-o').stdout
                        if 'syren_rtp_receive:receive_FL' in ports:
                            break
                    except (subprocess.CalledProcessError, StopIteration):
                        pass
                    time.sleep(0.2)
                else:
                    raise RuntimeError('Receiver ports did not appear')
                self.set_volume(10, True)
                for channel in ['FL', 'FR']:
                    self.command('pw-link', f'syren_rtp_receive:receive_{channel}',
                                 f'syren_hifiberry:playback_{channel}')
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    hardware = Path('/proc/asound/sndrpihifiberry/pcm0p/sub0/hw_params').read_text()
                    if f'period_size: {period}\n' in hardware and 'rate: 48000 ' in hardware:
                        if f'buffer_size: {period * 3}\n' in hardware and 'channels: 2\n' in hardware:
                            self.period = period
                            attempts.append({'requested_period': period, 'hw_params': hardware})
                            atomic_json(self.directory / 'negotiation.json', attempts)
                            return
                    time.sleep(0.2)
                raise RuntimeError(f'ALSA did not negotiate {period} frames and three periods: {hardware}')
            except Exception as error:
                attempts.append({'requested_period': period, 'error': str(error)})
                atomic_json(self.directory / 'negotiation.json', attempts)
                self.stop()
                if period == 256:
                    raise
                self.logger.warning('Retrying with 256 frames: %s', error)


def worker(arguments):
    directory = RUNTIME / arguments.session
    receiver = Receiver(directory, arguments.latency)
    telemetry_stop = threading.Event()

    def telemetry():
        while not telemetry_stop.is_set():
            try:
                with (directory / 'telemetry.jsonl').open('a') as output:
                    sample = collect(receiver.environment)
                    sample['scheduler'] = diagnostic(['ps', '-L', '-p', str(receiver.process.pid),
                                                       '-o', 'pid,tid,comm,cls,rtprio,ni'])
                    output.write(json.dumps(sample) + '\n')
            except Exception as error:
                receiver.logger.warning('Telemetry failed: %s', error)
            telemetry_stop.wait(30)

    try:
        receiver.start()
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(directory / 'control.sock'))
            server.listen(4)
            server.settimeout(0.5)
            last_heartbeat = time.monotonic()
            threading.Thread(target=telemetry, daemon=True).start()
            while not stopping and receiver.process.poll() is None:
                if time.monotonic() - last_heartbeat > LEASE_SECONDS:
                    raise RuntimeError('Laptop heartbeat expired')
                try:
                    connection, address = server.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(2)
                    try:
                        request = json.loads(connection.makefile('r').readline(4096))
                        action = request['action']
                        if action == 'heartbeat':
                            receiver.check_health(expect_rtp=request.get('expect_rtp', False))
                            last_heartbeat = time.monotonic()
                        elif action == 'stop':
                            receiver.set_volume(receiver.volume, True)
                            connection.sendall(b'{"stopping":true}\n')
                            break
                        elif action == 'volume':
                            volume = request['percent']
                            receiver.adjust(volume, request.get('muted', receiver.muted))
                        elif action == 'status':
                            receiver.check_health()
                        else:
                            raise ValueError('Unknown control action')
                        reply = {'running': True, 'session': arguments.session,
                                 'pipewire_pid': receiver.process.pid,
                                 'percent': receiver.volume, 'muted': receiver.muted,
                                 'receiving_rtp': receiver.receiving,
                                 'requested_latency_ms': receiver.latency,
                                 'negotiated_period': receiver.period}
                    except Exception as error:
                        reply = {'error': str(error)}
                    connection.sendall((json.dumps(reply) + '\n').encode())
            if receiver.process.poll() is not None:
                raise RuntimeError('Receiver failed')
    finally:
        telemetry_stop.set()
        receiver.stop()


def request(session, payload):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(RUNTIME / session / 'control.sock'))
        connection.sendall((json.dumps(payload) + '\n').encode())
        response = json.loads(connection.makefile('r').readline(65536))
        if 'error' in response:
            raise RuntimeError(response['error'])
        return response


def session_name(value):
    if not re.fullmatch('[a-f0-9]{32}', value):
        raise argparse.ArgumentTypeError('Invalid session identifier')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'launch', 'supervise', 'worker',
                                           'restore', 'request', 'channel'])
    parser.add_argument('--session', type=session_name)
    parser.add_argument('--user')
    parser.add_argument('--latency', type=int, choices=[10, 15, 20, 30, 40], default=20)
    parser.add_argument('--payload')
    arguments = parser.parse_args()
    for signum in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
        signal.signal(signum, stop_signal)
    if arguments.action in ['launch', 'supervise', 'restore'] and os.geteuid() != 0:
        parser.error('This lifecycle action requires sudo')
    if arguments.action in ['launch', 'supervise', 'worker', 'request', 'channel'] and not arguments.session:
        parser.error('--session is required')
    if arguments.action == 'check':
        return check()
    if arguments.action == 'launch':
        return launch(arguments)
    if arguments.action == 'supervise':
        return supervise(arguments)
    if arguments.action == 'restore':
        active = run(['systemctl', 'is-active', 'syren-rtp.service'], check=False).stdout.strip()
        if active in ('active', 'activating'):
            raise RuntimeError('Stop the receiver unit before manual restoration')
        restore()
    if arguments.action == 'worker':
        worker(arguments)
    if arguments.action == 'request':
        print(json.dumps(request(arguments.session, json.loads(arguments.payload))))
    if arguments.action == 'channel':
        for line in sys.stdin:
            print(json.dumps(request(arguments.session, json.loads(line))), flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(f'RTP receiver: {error}', file=sys.stderr)
        sys.exit(1)
