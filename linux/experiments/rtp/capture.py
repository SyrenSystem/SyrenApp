#!/usr/bin/env python3
"""Record a selected Wayland window and the laptop microphone together."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import threading
import uuid

import gi

gi.require_version('Gst', '1.0')
from gi.repository import Gio, GLib, Gst


PORTAL = 'org.freedesktop.portal.Desktop'
PORTAL_PATH = '/org/freedesktop/portal/desktop'
SCREENCAST = 'org.freedesktop.portal.ScreenCast'


class CaptureTiming:
    def __init__(self, duration, clock=time.monotonic):
        self.duration = duration
        self.clock = clock
        self.video_ready = False
        self.audio_ready = False
        self.ready_at = None
        self.marker_at = None

    def ready(self):
        if self.video_ready and self.audio_ready and self.ready_at is None:
            self.ready_at = self.clock()
        return self.ready_at is not None

    def mark(self):
        if not self.ready():
            raise ValueError('Wait for both microphone and screen capture readiness')
        if self.marker_at is None:
            self.marker_at = self.clock()

    def expired(self):
        return self.marker_at is not None and self.clock() - self.marker_at >= self.duration


class Portal:
    def __init__(self):
        self.connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.session = None
        self.descriptor = None

    def request(self, method, signature, arguments, options):
        token = 'syren_' + uuid.uuid4().hex
        options = dict(options, handle_token=GLib.Variant('s', token))
        sender = self.connection.get_unique_name()[1:].replace('.', '_')
        request_path = PORTAL_PATH + '/request/' + sender + '/' + token
        loop = GLib.MainLoop()
        response = []

        def received(connection, sender_name, object_path, interface_name, signal_name, parameters):
            response.extend(parameters.unpack())
            loop.quit()

        def timed_out():
            loop.quit()
            return GLib.SOURCE_REMOVE

        subscription = self.connection.signal_subscribe(PORTAL, 'org.freedesktop.portal.Request',
            'Response', request_path, None, Gio.DBusSignalFlags.NONE, received)
        timeout = GLib.timeout_add_seconds(300, timed_out)
        try:
            self.connection.call_sync(PORTAL, PORTAL_PATH, SCREENCAST, method,
                GLib.Variant(signature, (*arguments, options)), GLib.VariantType('(o)'),
                Gio.DBusCallFlags.NONE, 10000, None)
            loop.run()
            if not response or response[0] != 0:
                raise RuntimeError('Screen sharing was cancelled, declined, or timed out')
            return response[1]
        finally:
            self.connection.signal_unsubscribe(subscription)
            if response:
                GLib.source_remove(timeout)

    def open(self):
        created = self.request('CreateSession', '(a{sv})', (),
            {'session_handle_token': GLib.Variant('s', 'syren_' + uuid.uuid4().hex)})
        self.session = created['session_handle']
        self.request('SelectSources', '(oa{sv})', (self.session,),
            {'types': GLib.Variant('u', 3), 'multiple': GLib.Variant('b', False),
             'cursor_mode': GLib.Variant('u', 1), 'persist_mode': GLib.Variant('u', 0)})
        print('Choose the browser window containing the paused test clip in the desktop sharing picker.', flush=True)
        selected = self.request('Start', '(osa{sv})', (self.session, ''), {})
        response, descriptors = self.connection.call_with_unix_fd_list_sync(PORTAL, PORTAL_PATH,
            SCREENCAST, 'OpenPipeWireRemote', GLib.Variant('(oa{sv})', (self.session, {})),
            GLib.VariantType('(h)'), Gio.DBusCallFlags.NONE, 10000, None, None)
        self.descriptor = descriptors.get(response.unpack()[0])
        return selected

    def close(self):
        if self.session:
            try:
                self.connection.call_sync(PORTAL, self.session, 'org.freedesktop.portal.Session',
                    'Close', None, None, Gio.DBusCallFlags.NONE, 3000, None)
            except GLib.Error:
                pass
        if self.descriptor is not None:
            os.close(self.descriptor)


def pulse_sources():
    return json.loads(subprocess.check_output(['pactl', '--format=json', 'list', 'sources']))


def bounded_call(action, timeout=3):
    failures = []

    def run():
        try:
            action()
        except Exception as error:
            failures.append(error)

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(timeout)
    if worker.is_alive():
        raise TimeoutError('Audio pipeline operation timed out')
    if failures:
        raise failures[0]


def restore_microphone(name, percent, saved_volumes):
    current = next((item for item in pulse_sources() if item['name'] == name), None)
    expected = round(65536 * percent / 100)
    if current and all(abs(channel['value'] - expected) <= 1 for channel in current['volume'].values()):
        subprocess.run(['pactl', 'set-source-volume', name, *saved_volumes], check=True, timeout=5)
        return True
    return False


def record(arguments):
    Gst.init(None)
    output_path = Path(arguments.output).resolve()
    if output_path.exists():
        raise ValueError('Recording already exists; choose a new output path')
    output_path.parent.mkdir(parents=True, exist_ok=True)
    source = next(item for item in pulse_sources() if item['name'] == arguments.microphone)
    if source['name'].endswith('.monitor') or source['mute']:
        raise ValueError('Select an unmuted physical microphone')
    saved_volumes = [str(channel['value']) for channel in source['volume'].values()]
    portal = Portal()
    pipeline = None
    microphone_changed = False
    metadata = {'recording': str(output_path), 'started_at': time.time(), 'kind': 'screen-microphone',
                'microphone': source, 'requested_microphone_percent': arguments.microphone_percent,
                'speaker_distances_m': arguments.distances, 'path': arguments.path,
                'duration_limit_seconds': arguments.duration,
                'timestamps': 'Native video and microphone timestamps in one GStreamer system clock pipeline; no duplicated frames.'}
    metadata_path = output_path.with_suffix('.capture.json')
    errors = []
    timing = CaptureTiming(arguments.duration)
    marker_path = Path(arguments.marker_file).resolve()
    if marker_path.exists():
        raise ValueError('Choose an absent marker file; create it only after capture reports ready')
    try:
        selected = portal.open()
        metadata['portal'] = selected
        node_id, stream_properties = selected['streams'][0]
        pipeline = Gst.parse_launch(
            'pipewiresrc name=screen do-timestamp=false keepalive-time=0 ! '
            'queue ! videoscale ! videoconvert ! video/x-raw,format=I420,width=1280 ! '
            'x264enc speed-preset=ultrafast tune=zerolatency pass=quant quantizer=18 threads=2 ! '
            'h264parse ! queue ! mux. '
            'pulsesrc name=microphone provide-clock=false do-timestamp=false buffer-time=200000 latency-time=10000 ! '
            'audio/x-raw,format=S16LE,rate=48000,channels=2 ! queue ! mux. '
            'matroskamux name=mux ! filesink name=output')
        pipeline.use_clock(Gst.SystemClock.obtain())
        screen = pipeline.get_by_name('screen')
        screen.set_property('fd', portal.descriptor)
        if 'pipewire-serial' in stream_properties:
            screen.set_property('target-object', str(stream_properties['pipewire-serial']))
        else:
            screen.set_property('path', str(node_id))
        microphone = pipeline.get_by_name('microphone')
        microphone.set_property('device', arguments.microphone)
        microphone.set_property('client-name', 'Syren sync measurement')
        pipeline.get_by_name('output').set_property('location', str(output_path))
        loop = GLib.MainLoop()
        first_frame = True
        frame_count = 0
        stopping = False

        with output_path.with_suffix('.frames.jsonl').open('w', buffering=1) as frame_output:
            def frame_arrived(pad, information):
                nonlocal first_frame, frame_count
                buffer = information.get_buffer()
                frame_count += 1
                frame_output.write(json.dumps({'pts_ns': buffer.pts, 'duration_ns': buffer.duration}) + '\n')
                if first_frame:
                    first_frame = False
                    metadata['source_video_caps'] = pad.get_current_caps().to_string()
                    metadata_path.write_text(json.dumps(metadata, indent=2))
                if frame_count == 5:
                    timing.video_ready = True
                return Gst.PadProbeReturn.OK

            screen.get_static_pad('src').add_probe(Gst.PadProbeType.BUFFER, frame_arrived)

            def microphone_arrived(pad, information):
                timing.audio_ready = True
                return Gst.PadProbeReturn.OK

            microphone.get_static_pad('src').add_probe(Gst.PadProbeType.BUFFER, microphone_arrived)

            def message_received(bus, message):
                if message.type == Gst.MessageType.ERROR:
                    error, detail = message.parse_error()
                    errors.append(str(error) + ': ' + str(detail))
                    loop.quit()
                elif message.type == Gst.MessageType.EOS:
                    loop.quit()

            def stop_recording(*unused):
                nonlocal stopping
                if stopping:
                    return GLib.SOURCE_REMOVE
                stopping = True
                print('Finishing recording.', flush=True)

                def expired():
                    errors.append('Recording did not finish within eight seconds')
                    loop.quit()
                    return GLib.SOURCE_REMOVE

                GLib.timeout_add_seconds(8, expired)
                threading.Thread(target=lambda: pipeline.send_event(Gst.Event.new_eos()), daemon=True).start()
                return GLib.SOURCE_REMOVE

            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect('message', message_received)
            for signum in [signal.SIGINT, signal.SIGTERM]:
                GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, stop_recording)
            subprocess.run(['pactl', 'set-source-volume', arguments.microphone,
                            str(arguments.microphone_percent) + '%'], check=True)
            microphone_changed = True
            metadata['microphone_during_capture'] = next(item for item in pulse_sources()
                                                        if item['name'] == arguments.microphone)
            if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
                raise RuntimeError('Capture pipeline did not start')
            waiting_since = time.monotonic()
            announced = False

            def check_timing():
                nonlocal announced
                if stopping:
                    return GLib.SOURCE_REMOVE
                if timing.ready() and not announced:
                    announced = True
                    metadata['capture_ready_at'] = time.time()
                    metadata_path.write_text(json.dumps(metadata, indent=2))
                    print('Screen and microphone capture ready. Start the clip and create the operator marker: ' + str(marker_path), flush=True)
                if marker_path.exists() and timing.marker_at is None:
                    if not timing.ready() or marker_path.stat().st_mtime < metadata.get('capture_ready_at', time.time()):
                        errors.append('Operator marker arrived before capture readiness')
                        return stop_recording()
                    timing.mark()
                    metadata['operator_marker_at'] = time.time()
                    metadata['operator_marker_monotonic'] = timing.marker_at
                    metadata['operator_marker_pipeline_ns'] = pipeline.get_clock().get_time() - pipeline.get_base_time()
                    metadata_path.write_text(json.dumps(metadata, indent=2))
                if timing.expired():
                    return stop_recording()
                if timing.marker_at is None and time.monotonic() - waiting_since >= 300:
                    errors.append('Capture readiness or operator marker timed out after 300 seconds')
                    return stop_recording()
                return GLib.SOURCE_CONTINUE

            GLib.timeout_add(50, check_timing)
            loop.run()
            metadata['actual_microphone_buffer_us'] = microphone.get_property('actual-buffer-time')
            metadata['actual_microphone_latency_us'] = microphone.get_property('actual-latency-time')
            metadata['native_video_frames'] = frame_count
            bounded_call(lambda: pipeline.set_state(Gst.State.NULL))
        if errors:
            raise RuntimeError('; '.join(errors))
        if frame_count < 5:
            raise RuntimeError('Too few screen frames were captured; the video may have stalled')
        print('Recording saved: ' + str(output_path), flush=True)
    except Exception as error:
        if str(error) not in errors:
            errors.append(str(error))
        raise
    finally:
        try:
            if microphone_changed:
                metadata['microphone_restored'] = restore_microphone(
                    arguments.microphone, arguments.microphone_percent, saved_volumes)
        finally:
            try:
                portal.close()
                if pipeline:
                    bounded_call(lambda: pipeline.set_state(Gst.State.NULL))
            except Exception as error:
                errors.append(str(error))
            metadata['finished_at'] = time.time()
            metadata['errors'] = errors
            metadata_path.write_text(json.dumps(metadata, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--path', choices=['local', 'snapcast', 'rtp20', 'rtp15', 'rtp10', 'rtp30', 'rtp40'], required=True)
    parser.add_argument('--microphone', default='alsa_input.pci-0000_00_1f.3.analog-stereo')
    parser.add_argument('--microphone-percent', type=int, default=25)
    parser.add_argument('--duration', type=int, default=180)
    parser.add_argument('--marker-file', required=True,
                        help='Create this absent file after capture reports ready and you start the clip')
    parser.add_argument('--distances', type=float, nargs='+', default=[],
                        help='Speaker distances in metres; omit while awaiting measurement')
    arguments = parser.parse_args()
    if not 1 <= arguments.microphone_percent <= 100 or not 30 <= arguments.duration <= 7200:
        parser.error('Use microphone gain 1 to 100 and a duration of 30 to 7200 seconds')
    if any(not 0 <= distance <= 20 for distance in arguments.distances):
        parser.error('Speaker distances must be between 0 and 20 metres')
    lock_path = Path(os.environ.get('XDG_RUNTIME_DIR', '/tmp')) / ('syren-capture-' + str(os.getuid()) + '.lock')
    with lock_path.open('a') as capture_lock:
        try:
            fcntl.flock(capture_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error('Another sync recorder is already running')
        record(arguments)


if __name__ == '__main__':
    main()
