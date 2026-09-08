"""Keep Snapcast and RTP advancing through one hardware output."""

import json
import os
import subprocess
import time

from graph import AudioGraph, INSTALL


class SharedAudioGraph(AudioGraph):
    template_name = 'shared-receiver.conf.in'
    volume_node = 'syren_rtp_gain'

    def __init__(self, *arguments, snapcast):
        super().__init__(*arguments)
        self.snapcast = snapcast
        self.children = []
        self.selected_source = 'snapcast'
        self.snapcast_muted = True
        self.snapcast_node = None

    def connect_audio(self):
        for channel in ['FL', 'FR']:
            self.command('pw-link', f'syren_rtp_receive:receive_{channel}',
                         f'syren_rtp_gain:playback_{channel}')
            for source in ['rtp', 'snapcast']:
                self.command('pw-link', f'syren_{source}_gain:monitor_{channel}',
                             f'syren_hifiberry:playback_{channel}')

    def stage(self, name, percent, muted):
        objects = json.loads(self.command('pw-dump').stdout)
        node = next(item for item in objects if
                    item.get('info', {}).get('props', {}).get('node.name') == f'syren_{name}_gain')
        fraction = percent / 100
        self.command('pw-cli', 'set-param', str(node['id']), 'Props',
                     f'{{ mute = {str(muted).lower()} channelVolumes = [ {fraction} {fraction} ] }}')
        objects = json.loads(self.command('pw-dump').stdout)
        properties = next(item['info']['params']['Props'][0] for item in objects if item['id'] == node['id'])
        if properties['mute'] != muted or any(abs(value - fraction) > 0.00001 for value in properties['channelVolumes']):
            raise RuntimeError('Shared output gain or mute was not confirmed')
        if name == 'snapcast':
            self.snapcast_muted = muted

    def standby(self, muted=False):
        self.stage('rtp', self.volume, True)
        self.muted = True
        self.stage('snapcast', 100, muted)
        self.selected_source = 'snapcast'

    def mute_all(self, percent):
        self.stage('snapcast', 100, True)
        super().set_volume(percent, True)

    def set_volume(self, volume, muted):
        if not muted:
            self.stage('snapcast', 100, True)
        super().set_volume(volume, muted)
        if not muted:
            self.selected_source = 'rtp'

    def start_child(self, command, environment=None):
        process = subprocess.Popen(command, env=environment or self.environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.children.append(process)
        import threading
        threading.Thread(target=self.log_output, args=(process,), daemon=True).start()
        return process

    def start(self):
        super().start()
        pulse_configuration = self.directory / 'pulse.conf'
        pulse_configuration.write_text((INSTALL / 'templates/pulse.conf').read_text())
        self.start_child(['pipewire', '-c', str(pulse_configuration)])
        pulse_socket = self.directory / 'pulse/native'
        expires = time.monotonic() + 3
        while not pulse_socket.exists():
            if self.stopped.is_set() or time.monotonic() >= expires or self.children[-1].poll() is not None:
                raise RuntimeError('Private Snapcast audio connection did not start')
            time.sleep(0.02)
        environment = dict(self.environment, PULSE_SERVER=f'unix:{pulse_socket}')
        self.start_child(['snapclient', '--host', self.snapcast['host'], '--port', str(self.snapcast['port']),
                          '--hostID', self.snapcast['id'], '--player', 'pulse', '--soundcard', 'syren_snapcast_gain',
                          '--mixer', 'software', '--sampleformat', '48000:16:*', '--logsink', 'stdout'], environment)
        self.standby()

    def check_health(self):
        super().check_health()
        if any(process.poll() is not None for process in self.children):
            raise RuntimeError('Shared Snapcast audio process exited')
        objects = json.loads(self.command('pw-dump').stdout)
        stages = [item for item in objects if item.get('info', {}).get('props', {}).get('node.name') in ('syren_rtp_gain', 'syren_snapcast_gain')]
        if len(stages) != 2 or any(item['info']['state'] != 'running' for item in stages):
            raise RuntimeError('Shared audio stages stopped advancing')
        self.connect_snapcast(objects)

    def connect_snapcast(self, objects):
        self.snapcast_node = None
        ports = [item for item in objects if item.get('type') == 'PipeWire:Interface:Port']
        links = {
            (item['info']['props'].get('link.output.port'), item['info']['props'].get('link.input.port'))
            for item in objects if item.get('type') == 'PipeWire:Interface:Link'
        }
        gain = next(item for item in objects if
                    item.get('info', {}).get('props', {}).get('node.name') == 'syren_snapcast_gain')
        for item in objects:
            properties = item.get('info', {}).get('props', {})
            if properties.get('node.name') != 'syren_snapclient':
                continue
            output_ports = [port for port in ports if port.get('info', {}).get('props', {}).get('node.id') == item['id']
                            and port.get('info', {}).get('props', {}).get('port.direction') == 'out']
            for channel in ['FL', 'FR']:
                output = next((port for port in output_ports if port['info']['props'].get('audio.channel') == channel), None)
                if output is None:
                    continue
                target = next(port for port in ports if port.get('info', {}).get('props', {}).get('node.id') == gain['id']
                              and port['info']['props'].get('port.direction') == 'in'
                              and port['info']['props'].get('audio.channel') == channel)
                if (output['id'], target['id']) not in links:
                    self.command('pw-link', str(output['id']), str(target['id']))
            if len(output_ports) >= 2:
                self.snapcast_node = item['id']

    def stop(self, cancel=True):
        for process in reversed(self.children):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=0.03)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=0.15)
        self.children.clear()
        return super().stop(cancel=cancel)
