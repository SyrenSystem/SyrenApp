"""Run and inspect a private PipeWire graph."""

import json
import logging
import logging.handlers
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time

from common import atomic_json, run

INSTALL = Path(__file__).resolve().parent


class AudioGraph:
    template_name = 'receiver.conf.in'
    volume_node = 'syren_hifiberry'

    def connect_audio(self):
        for channel in ['FL', 'FR']:
            self.command('pw-link', f'syren_rtp_receive:receive_{channel}',
                         f'syren_hifiberry:playback_{channel}')

    def __init__(self, directory, latency, device, hardware_path, port):
        self.directory = directory
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.device = device
        self.hardware_path = Path(hardware_path)
        self.port = port
        self.stopped = threading.Event()
        shutil.copyfile('/usr/share/pipewire/client.conf', directory / 'client.conf')
        self.latency = latency
        self.process = None
        self.output_id = None
        self.volume = 10
        self.muted = None
        self.period = None
        self.receiving = None
        self.missing_rtp_since = None
        self.environment = dict(os.environ, XDG_RUNTIME_DIR=str(directory),
                                PIPEWIRE_RUNTIME_DIR=str(directory),
                                PIPEWIRE_REMOTE='syren-rtp', PIPEWIRE_DEBUG='3',
                                PIPEWIRE_CONFIG_DIR=str(directory))
        self.logger = logging.getLogger('receiver.' + directory.name)
        self.logger.setLevel(logging.INFO)
        handler = logging.handlers.RotatingFileHandler(
            directory / 'pipewire.log', maxBytes=10 * 1024 * 1024, backupCount=3)
        self.logger.addHandler(handler)

    def command(self, *arguments):
        return run(list(arguments), env=self.environment, timeout=2)

    def stop(self, cancel=True):
        if cancel:
            self.stopped.set()
        process = self.process
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=0.03)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=0.15)
        return not process or process.poll() is not None

    def dispose(self):
        self.stop()
        for handler in list(self.logger.handlers):
            handler.close()
            self.logger.removeHandler(handler)
        shutil.rmtree(self.directory)

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

    def check_health(self):
        hardware = self.hardware_path.read_text()
        if (f'period_size: {self.period}\n' not in hardware or 'rate: 48000 ' not in hardware
                or 'channels: 2\n' not in hardware or 'format: S32_LE\n' not in hardware
                or f'buffer_size: {self.period * 3}\n' not in hardware):
            raise RuntimeError('HiFiBerry stopped using the negotiated audio format')
        objects = json.loads(self.command('pw-dump').stdout)
        nodes = [item['info'] for item in objects if item.get('info', {}).get('props', {}).get('node.name')
                 in ['syren_hifiberry', 'syren_rtp_receive']]
        if len(nodes) != 2 or any(node['state'] != 'running' for node in nodes):
            raise RuntimeError('Receiver audio graph stopped running')
        source = next(node for node in nodes if node['props']['node.name'] == 'syren_rtp_receive')
        self.receiving = source['props'].get('rtp.receiving') in [True, 'true']
    def start(self):
        attempts = []
        for period in [128, 256]:
            configuration = (INSTALL / 'templates' / self.template_name).read_text()
            configuration = configuration.replace('@LATENCY@', str(self.latency))
            configuration = configuration.replace('@PERIOD@', str(period))
            configuration = configuration.replace('@PORT@', str(self.port)).replace('@DEVICE@', self.device)
            configuration_path = self.directory / 'receiver.conf'
            configuration_path.write_text(configuration)
            if self.stopped.is_set():
                raise RuntimeError('Audio graph cancelled')
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
                                              == self.volume_node)
                        ports = self.command('pw-link', '-o').stdout
                        if 'syren_rtp_receive:receive_FL' in ports:
                            break
                    except (subprocess.CalledProcessError, StopIteration):
                        pass
                    time.sleep(0.2)
                else:
                    raise RuntimeError('Receiver ports did not appear')
                self.set_volume(10, True)
                self.connect_audio()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    hardware = self.hardware_path.read_text()
                    if f'period_size: {period}\n' in hardware and 'rate: 48000 ' in hardware:
                        if f'buffer_size: {period * 3}\n' in hardware and 'channels: 2\n' in hardware and 'format: S32_LE\n' in hardware:
                            self.period = period
                            attempts.append({'requested_period': period, 'hw_params': hardware})
                            atomic_json(self.directory / 'negotiation.json', attempts)
                            return
                    time.sleep(0.2)
                raise RuntimeError(f'ALSA did not negotiate {period} frames and three periods: {hardware}')
            except Exception as error:
                attempts.append({'requested_period': period, 'error': str(error)})
                atomic_json(self.directory / 'negotiation.json', attempts)
                self.stop(cancel=False)
                if period == 256:
                    raise
                self.logger.warning('Retrying with 256 frames: %s', error)
