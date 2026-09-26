"""Keep independent session inputs connected to one persistent output."""

import hashlib
import json
import math
import os
import re
import resource
import subprocess
import threading
import time
from urllib.parse import urlparse
import uuid

from ingress import Ingress, PacketFilter
from session_control import PipeWireControl

from graph import AudioGraph, INSTALL


# Real time priorities for the playback path, highest at the hardware output; the service allows up to 88.
OUTPUT_PRIORITY = 88
BRIDGE_PRIORITY = 87
INPUT_PRIORITY = 86


def realtime_priority(wanted):
    # Returns the highest allowed priority up to the wanted one, or None when real time is not allowed.
    if os.geteuid() == 0:
        return wanted
    limit = resource.getrlimit(resource.RLIMIT_RTPRIO)[0]
    if limit == resource.RLIM_INFINITY:
        return wanted
    return min(wanted, limit) if limit > 0 else None


def realtime_command(command, wanted):
    priority = realtime_priority(wanted)
    return ['chrt', '--fifo', str(priority), *command] if priority else command


def run_realtime(target, wanted):
    priority = realtime_priority(wanted)
    if priority:
        try:
            # On Linux this changes only the calling thread.
            os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(priority))
        except OSError:
            pass
    target()


def with_priority(configuration, priority):
    return re.sub(r'#?rt\.prio\s*=\s*\d+', f'rt.prio = {priority}', configuration, count=1)


def snapclient_identity(physical_id, transport_id):
    return 'syren-' + hashlib.sha256((physical_id + '\0' + transport_id).encode()).hexdigest()[:24]


class SessionOutputGraph(AudioGraph):
    def __init__(self, directory, device, hardware_path, physical_id, snapcast_host, snapcast_port=1704):
        super().__init__(directory, 20, device, hardware_path, 1)
        self.physical_id = physical_id
        self.snapcast_host = snapcast_host
        self.snapcast_port = snapcast_port
        self.inputs = {}
        self.orphans = set()
        self.pulse = None
        self.control = None
        self.guard = threading.RLock()
        self.environment['PIPEWIRE_DEBUG'] = '2'

    def spawn(self, command, environment=None):
        process = subprocess.Popen(command, env=environment or self.environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        threading.Thread(target=self.log_output, args=(process,), daemon=True).start()
        return process

    def start(self):
        # Clients such as the RTP source read this copy, so their data loops run just below the output.
        client_configuration = self.directory / 'client.conf'
        if client_configuration.exists():
            client_configuration.write_text(with_priority(client_configuration.read_text(), BRIDGE_PRIORITY))
        for period in (128, 256):
            configuration = (INSTALL / 'templates/session-output.conf.in').read_text()
            configuration = configuration.replace('@DEVICE@', self.device).replace('@PERIOD@', str(period))
            configuration_path = self.directory / 'session-output.conf'
            configuration_path.write_text(configuration)
            self.process = self.spawn(['pipewire', '-c', str(configuration_path)])
            try:
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if self.process.poll() is not None:
                        raise RuntimeError('Session output exited during startup')
                    try:
                        self.command('pw-link', 'syren_output_bus:monitor_FL', 'syren_hifiberry:playback_FL')
                        self.command('pw-link', 'syren_output_bus:monitor_FR', 'syren_hifiberry:playback_FR')
                        self.period = period
                        hardware = self.hardware_path.read_text()
                        if any(value not in hardware for value in (f'period_size: {period}\n', 'rate: 48000 ',
                            'channels: 2\n', 'format: S32_LE\n', f'buffer_size: {period * 3}\n')):
                            raise RuntimeError('Output did not confirm the negotiated audio format')
                        break
                    except subprocess.CalledProcessError:
                        time.sleep(0.05)
                else:
                    raise RuntimeError('Session output ports did not appear')
                break
            except Exception:
                self.stop(cancel=False)
                if period == 256:
                    raise
        pulse_configuration = self.directory / 'pulse.conf'
        pulse_configuration.write_text(with_priority((INSTALL / 'templates/pulse.conf').read_text().replace(
            '    node.name = syren_snapclient\n', ''), BRIDGE_PRIORITY))
        self.pulse = self.spawn(['pipewire', '-c', str(pulse_configuration)])
        deadline = time.monotonic() + 3
        while not (self.directory / 'pulse/native').exists():
            if self.pulse.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('Session Pulse server did not start')
            time.sleep(0.02)

        self.control = PipeWireControl(self.environment)

    def ensure_snapcast(self, session_id, transport, expect_audio=True):
        with self.guard:
            identity = transport['id']
            existing = self.inputs.get(identity)
            if existing is not None:
                existing['sessionId'] = session_id
                if not expect_audio:
                    existing['missingSince'] = None
                failed = expect_audio and existing.get('missingSince') is not None and time.monotonic() - existing['missingSince'] >= 3
                if existing['process'].poll() is None and not failed:
                    return
                self.remove(identity)
            endpoint = transport['endpoint']
            node_name = self.stage_name(identity)
            client_id = snapclient_identity(self.physical_id, identity)
            environment = dict(self.environment, PULSE_SERVER=f'unix:{self.directory}/pulse/native')
            process = None
            try:
                self.create_stage(node_name)
                process = self.spawn(realtime_command(
                    ['snapclient', '--host', self.snapcast_host, '--port', str(self.snapcast_port),
                     '--hostID', client_id, '--player', 'pulse', '--soundcard', node_name,
                     '--mixer', 'software', '--sampleformat', '48000:16:*', '--logsink', 'stdout'], INPUT_PRIORITY), environment)
            except Exception:
                self.discard(node_name, process)
                raise
            self.inputs[identity] = {'sessionId': session_id, 'transportId': identity,
                                     'clientId': client_id, 'endpoint': endpoint,
                                     'node': node_name, 'process': process, 'gain': 0.0,
                                     'muted': True, 'receiving': False, 'missingSince': None}

    @staticmethod
    def stage_name(identity):
        token = hashlib.sha256(identity.encode()).hexdigest()[:24]
        # Each stage gets a new name so a stage left by a failed removal never takes its links.
        return 'syren_gain_' + token + '_' + uuid.uuid4().hex[:8]

    def create_stage(self, node_name):
        properties = {
            'factory.name': 'support.null-audio-sink', 'node.name': node_name,
            'audio.format': 'F32', 'media.class': 'Audio/Sink', 'audio.position': ['FL', 'FR'], 'audio.channels': 2,
            'audio.rate': 48000, 'node.always-process': True, 'object.linger': True,
            'monitor.channel-volumes': True,
            'node.param.Props': {'mute': True, 'channelVolumes': [0.0, 0.0]},
            'adapter.auto-port-config': {'mode': 'dsp', 'monitor': True, 'position': 'preserve'},
        }
        self.command('pw-cli', 'create-node', 'adapter', json.dumps(properties))
        for channel in ('FL', 'FR'):
            self.command('pw-link', f'{node_name}:monitor_{channel}', f'syren_output_bus:playback_{channel}')

    def ensure_rtp(self, session_id, transport):
        with self.guard:
            identity = transport['id']
            if identity in self.inputs:
                self.inputs[identity]['sessionId'] = session_id
                if self.inputs[identity]['process'].poll() is None:
                    packet_filter = self.inputs[identity]['ingress'].filter
                    if packet_filter.source is None:
                        packet_filter.startup_deadline = time.monotonic() + 10
                    return
                self.remove(identity)
            endpoint = urlparse(transport['endpoint'])
            if endpoint.scheme != 'rtp' or not endpoint.username or not endpoint.hostname or not endpoint.port:
                raise ValueError('Invalid RTP endpoint')
            ingress = Ingress(endpoint.hostname, PacketFilter(endpoint.username, time.monotonic() + 10), endpoint.port)
            node_name = self.stage_name(identity)
            source_name = node_name + '_rtp'
            process = None
            try:
                port = ingress.prepare()
                self.create_stage(node_name)
                properties = {
                    'source.ip': '127.0.0.2', 'source.port': port, 'sess.media': 'audio',
                    'sess.latency.msec': 20, 'sess.min-ptime': 2.5, 'sess.max-ptime': 2.5,
                    'sess.ts-direct': False, 'sess.ignore-ssrc': True, 'stream.may-pause': False,
                    'audio.format': 'S16BE', 'audio.rate': 48000, 'audio.channels': 2,
                    'audio.position': ['FL', 'FR'],
                    'stream.props': {'node.name': source_name, 'node.autoconnect': False,
                                     'node.always-process': True, 'rtp.ptime': 2.5, 'rtp.payload': 127,
                                     'adapter.auto-port-config': {'mode': 'dsp', 'position': 'preserve'}},
                }
                process = self.spawn(['pw-cli', '-m', 'load-module', 'libpipewire-module-rtp-source', json.dumps(properties)])
                ingress.open()
            except Exception:
                self.discard(node_name, process, ingress)
                raise
            threading.Thread(target=run_realtime, args=(ingress.run, INPUT_PRIORITY), daemon=True).start()
            self.inputs[identity] = {'sessionId': session_id, 'transportId': identity, 'clientId': None,
                                     'endpoint': transport['endpoint'], 'node': node_name, 'sourceNode': source_name,
                                     'process': process, 'ingress': ingress, 'gain': 0.0, 'muted': True, 'receiving': False}

    def objects(self):
        return self.control.snapshot() if self.control else json.loads(self.command('pw-dump').stdout)

    def find_node(self, name, objects=None):
        return next((node for node in (self.objects() if objects is None else objects)
                     if node.get('info', {}).get('props', {}).get('node.name') == name), None)

    def healthy(self):
        return all(process is not None and process.poll() is None for process in (self.process, self.pulse)) and (
            self.control is not None and self.control.healthy())

    def stage(self, identity, gain):
        if not math.isfinite(gain) or not 0 <= gain <= 1:
            raise ValueError('Session gain must be between zero and one')
        item = self.inputs[identity]
        muted = gain <= 0
        if item['gain'] == gain and item['muted'] == muted:
            return
        self.control.gain(self.control.node(item['node']), gain, muted)
        item.update(gain=gain, muted=muted)

    def apply(self, gains_by_transport):
        with self.guard:
            changes = [(identity, gains_by_transport.get(identity, 0.0)) for identity in self.inputs]
            changes.sort(key=lambda change: change[1] > self.inputs[change[0]]['gain'])
            for identity, gain in changes:
                self.stage(identity, gain)

    def repair_links(self):
        with self.guard:
            objects = self.objects()
            ports = [item for item in objects if item.get('type') == 'PipeWire:Interface:Port']
            links = {(item['info']['props'].get('link.output.port'), item['info']['props'].get('link.input.port'))
                     for item in objects if item.get('type') == 'PipeWire:Interface:Link'}
            broken = []
            for identity, item in self.inputs.items():
                item['receiving'] = False
                if item['process'].poll() is not None:
                    continue
                stage = self.find_node(item['node'], objects)
                if stage is None:
                    broken.append(identity)
                    continue
                sources = [node for node in objects if (str(node.get('info', {}).get('props', {}).get('application.process.id')) == str(item['process'].pid) or
                           node.get('info', {}).get('props', {}).get('node.name') == item.get('sourceNode', ''))]
                connected = set()
                for source in sources:
                    for channel in ('FL', 'FR'):
                        output = next((port for port in ports if port['info']['props'].get('node.id') == source['id'] and
                                       port['info']['props'].get('port.direction') == 'out' and port['info']['props'].get('audio.channel') == channel), None)
                        target = next((port for port in ports if port['info']['props'].get('node.id') == stage['id'] and
                                       port['info']['props'].get('port.direction') == 'in' and port['info']['props'].get('audio.channel') == channel), None)
                        if output and target:
                            if (output['id'], target['id']) not in links:
                                try:
                                    self.command('pw-link', str(output['id']), str(target['id']))
                                except subprocess.CalledProcessError:
                                    continue
                            connected.add(channel)
                item['receiving'] = len(connected) == 2 and ('ingress' not in item or item['ingress'].filter.usable())
                if item['receiving']:
                    item['missingSince'] = None
                elif item.get('missingSince') is None:
                    item['missingSince'] = time.monotonic()
            for name in list(self.orphans):
                orphan = self.find_node(name, objects)
                if orphan is None or self.destroy(orphan):
                    self.orphans.discard(name)
            # The next tick creates these inputs again from the catalogue.
            for identity in broken:
                self.remove(identity)

    def status(self):
        with self.guard:
            return [{key: value for key, value in item.items() if key not in ('process', 'node', 'ingress', 'sourceNode', 'missingSince')}
                    for item in self.inputs.values()]

    def remove(self, identity):
        with self.guard:
            item = self.inputs.pop(identity)
            stage = None
            try:
                stage = self.find_node(item['node'])
                if stage is not None and not item['muted']:
                    self.control.gain(stage['id'], 0.0, True)
            finally:
                self.stop_child(item['process'])
                if 'ingress' in item:
                    item['ingress'].running = False
                    item['ingress'].close()
                # Destroying the stage silences it even when muting failed.
                if stage is not None and not self.destroy(stage):
                    self.orphans.add(item['node'])

    def discard(self, node_name, process=None, ingress=None):
        # Undo a partly created input so a failed attempt leaves nothing behind.
        self.stop_child(process)
        if ingress is not None:
            ingress.running = False
            ingress.close()
        try:
            stage = self.find_node(node_name)
        except (subprocess.SubprocessError, OSError, RuntimeError, ValueError):
            stage = None
        if stage is None or not self.destroy(stage):
            # The next link repair destroys the stage once PipeWire lists it.
            self.orphans.add(node_name)

    def destroy(self, node):
        try:
            self.command('pw-cli', 'destroy', str(node['id']))
        except (subprocess.SubprocessError, OSError, RuntimeError):
            return False
        return True

    @staticmethod
    def stop_child(process):
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)

    def stop(self, cancel=True):
        with self.guard:
            for item in self.inputs.values():
                self.stop_child(item['process'])
                if 'ingress' in item:
                    item['ingress'].running = False
                    item['ingress'].close()
            self.inputs.clear()
            self.orphans.clear()
            if self.control:
                self.control.close()
                self.control = None
            self.stop_child(self.pulse)
            self.pulse = None
            return super().stop(cancel=cancel)
