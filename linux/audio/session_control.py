"""Confirm node properties through persistent PipeWire connections."""

import codecs
import copy
import json
import os
import subprocess
import threading
import time


class PipeWireControl:
    def __init__(self, environment):
        self.condition = threading.Condition()
        self.nodes = {}
        self.failure = None
        self.stopped = False
        self.monitor = subprocess.Popen(['pw-dump', '--monitor'], env=dict(environment, PIPEWIRE_DEBUG='0'),
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.controller = subprocess.Popen(['pw-cli'], env=dict(environment, PIPEWIRE_DEBUG='0'),
                                           stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        threading.Thread(target=self.read_monitor, daemon=True).start()
        self.wait(lambda: bool(self.nodes))

    def read_monitor(self):
        decoder = json.JSONDecoder()
        # A character split across two reads is kept until the rest arrives.
        text_decoder = codecs.getincrementaldecoder('utf-8')()
        buffered = ''
        try:
            while not self.stopped:
                data = os.read(self.monitor.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError('PipeWire status connection closed')
                buffered += text_decoder.decode(data)
                while buffered.strip():
                    buffered = buffered.lstrip()
                    try:
                        update, length = decoder.raw_decode(buffered)
                    except json.JSONDecodeError:
                        break
                    buffered = buffered[length:]
                    with self.condition:
                        for item in update:
                            identity = item['id']
                            if item.get('info') is None:
                                self.nodes.pop(identity, None)
                            else:
                                self.merge(self.nodes.setdefault(identity, {}), item)
                        self.condition.notify_all()
        except (OSError, ValueError, RuntimeError) as error:
            with self.condition:
                self.failure = type(error).__name__
                self.condition.notify_all()

    @staticmethod
    def merge(previous, update):
        for key, value in update.items():
            if isinstance(value, dict) and isinstance(previous.get(key), dict):
                PipeWireControl.merge(previous[key], value)
            else:
                previous[key] = value

    def wait(self, predicate, timeout=2):
        deadline = time.monotonic() + timeout
        with self.condition:
            while not predicate():
                if self.failure or self.controller.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('PipeWire did not confirm the requested change')
                self.condition.wait(max(0, deadline - time.monotonic()))

    def healthy(self):
        return not self.failure and self.controller.poll() is None and self.monitor.poll() is None

    def snapshot(self):
        with self.condition:
            if self.failure:
                raise RuntimeError('PipeWire status connection failed')
            return copy.deepcopy(list(self.nodes.values()))

    def node(self, name):
        def find():
            return next((node for node in self.nodes.values() if node.get('info', {}).get('props', {}).get('node.name') == name), None)
        self.wait(find)
        with self.condition:
            return find()['id']

    def gain(self, identity, gain, muted):
        command = f'set-param {identity} Props ' + json.dumps({'mute': muted, 'channelVolumes': [gain, gain]}) + '\n'
        self.controller.stdin.write(command.encode())
        self.controller.stdin.flush()

        def confirmed():
            properties = self.nodes.get(identity, {}).get('info', {}).get('params', {}).get('Props', [])
            return bool(properties) and properties[0].get('mute') == muted and len(properties[0].get('channelVolumes', [])) == 2 and all(
                abs(actual - gain) < .00001 for actual in properties[0]['channelVolumes'])
        self.wait(confirmed)

    def close(self):
        self.stopped = True
        for process in (self.controller, self.monitor):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=.2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1)
        if self.controller.stdin:
            self.controller.stdin.close()
        if self.monitor.stdout:
            self.monitor.stdout.close()
