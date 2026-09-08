"""Restore only routes and stream identities still owned by RTP."""

import json
import os
from pathlib import Path
import signal
import time

from common import atomic_json, process_alive, read_json, run

LIVE_SINK = 'SyrenSystem_Live'
SENDER_SERVICE = 'syren-laptop-audio.service'


def snapshot():
    sinks = json.loads(run(['pactl', '--format=json', 'list', 'sinks']).stdout)
    sink_names = {item['index']: item['name'] for item in sinks}
    streams = json.loads(run(['pactl', '--format=json', 'list', 'sink-inputs']).stdout)
    return {'default': run(['pactl', 'get-default-sink']).stdout.strip(),
            'sinks': sink_names,
            'streams': {str(item['index']): {'sink': sink_names.get(item['sink']),
                        'serial': item.get('properties', {}).get('object.serial')}
                        for item in streams}}


def gains():
    result = {}
    for kind in ('sinks', 'sink-inputs'):
        objects = json.loads(run(['pactl', '--format=json', 'list', kind]).stdout)
        result[kind] = [{'index': item['index'], 'name': item.get('name'),
                         'serial': item.get('properties', {}).get('object.serial'),
                         'volume': item.get('volume'), 'muted': item.get('mute')}
                        for item in objects]
    return result


def apply_snapshot(wanted, from_sink):
    current = snapshot()
    available = set(current['sinks'].values())
    # Once the live sink is gone WirePlumber has already picked a fallback nobody chose, yet it still remembers the live sink as the configured default.
    fallen_back = from_sink not in available
    if current['default'] == from_sink and wanted['default'] in available:
        run(['pactl', 'set-default-sink', wanted['default']])
    elif fallen_back:
        # Setting the default explicitly overwrites the remembered live sink so it cannot become default again on the next start.
        target = wanted['default'] if wanted['default'] in available else current['default']
        if target:
            run(['pactl', 'set-default-sink', target])
    for stream_id, previous in wanted['streams'].items():
        present = current['streams'].get(stream_id)
        if not present or not previous['serial'] or present['serial'] != previous['serial']:
            continue
        # A stream on the fallback default was relinked by WirePlumber, while one elsewhere was moved by the user.
        owned = present['sink'] == from_sink or (fallen_back and present['sink'] == current['default'])
        if owned and previous['sink'] in available and present['sink'] != previous['sink']:
            result = run(['pactl', 'move-sink-input', stream_id, previous['sink']], check=False)
            if result.returncode:
                remaining = snapshot()['streams'].get(stream_id)
                if remaining == present:
                    raise RuntimeError(f'Could not restore stream {stream_id}')


def service_state():
    result = run(['systemctl', '--user', 'show', SENDER_SERVICE, '-p', 'ActiveState',
                  '-p', 'InvocationID', '-p', 'InactiveEnterTimestampMonotonic'])
    state = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    state['boot_id'] = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    return state


def stop_sender():
    run(['systemctl', '--user', 'stop', '--no-block', SENDER_SERVICE])
    for phase in range(2):
        expires = time.monotonic() + 2
        while time.monotonic() < expires:
            if service_state()['ActiveState'] in ('inactive', 'failed'):
                return
            time.sleep(0.1)
        run(['systemctl', '--user', 'kill', '--signal=SIGKILL', '--kill-whom=all', SENDER_SERVICE], check=False)
    raise RuntimeError('Laptop sender did not stop, including the unit scoped fallback')


def handoff(state, journal):
    current = service_state()
    if current['ActiveState'] not in ('active', 'inactive', 'failed'):
        raise RuntimeError('Laptop sender is changing state; retry after it settles')
    state['sender_before'] = current
    if current['ActiveState'] == 'active':
        marker = Path(os.environ['XDG_RUNTIME_DIR']) / 'syren-sender-restore-once'
        if read_json(marker, {}).get('session') == state['session']:
            marker.unlink()
        state['sender_stop_intended'] = True
        atomic_json(journal, state)
        stop_sender()
        state['sender_stopped'] = service_state()
        atomic_json(journal, state)


def route(state, journal):
    state['routing'] = snapshot()
    state['default_change_intended'] = True
    atomic_json(journal, state)
    run(['pactl', 'set-default-sink', LIVE_SINK])
    state['streams_intended'] = {}
    for stream_id, previous in state['routing']['streams'].items():
        current = snapshot()['streams'].get(stream_id)
        if current != previous or not previous['serial']:
            continue
        state['streams_intended'][stream_id] = previous
        atomic_json(journal, state)
        run(['pactl', 'move-sink-input', stream_id, LIVE_SINK], check=False)


def restore_routes(state):
    if not state.get('default_change_intended'):
        return
    wanted = dict(state['routing'], streams=state.get('streams_intended', {}))
    apply_snapshot(wanted, LIVE_SINK)
    current = snapshot()
    if current['default'] == LIVE_SINK:
        raise RuntimeError('Original default sink is unavailable; routing restoration remains pending')
    for stream_id, previous in wanted['streams'].items():
        present = current['streams'].get(stream_id)
        if present and present['serial'] == previous['serial'] and present['sink'] == LIVE_SINK:
            raise RuntimeError('Original stream sink is unavailable; routing restoration remains pending')


def stop_process(identity):
    if not process_alive(identity):
        return
    os.kill(identity[0], signal.SIGTERM)
    expires = time.monotonic() + 1
    while process_alive(identity) and time.monotonic() < expires:
        time.sleep(0.05)
    if process_alive(identity):
        os.kill(identity[0], signal.SIGKILL)
    expires = time.monotonic() + 1
    while process_alive(identity) and time.monotonic() < expires:
        time.sleep(0.05)
    if process_alive(identity):
        raise RuntimeError('Owned RTP sender termination remains unconfirmed')


def restore_sender(state, journal, confirm=False):
    if not state.get('sender_stop_intended'):
        return
    current = service_state()
    if current['ActiveState'] == 'active':
        state['sender_stop_intended'] = False
        atomic_json(journal, state)
        return
    if current != state.get('sender_stopped') and not confirm:
        raise RuntimeError('Laptop sender ownership is ambiguous; inspect the service and recover explicitly')
    marker = Path(os.environ['XDG_RUNTIME_DIR']) / 'syren-sender-restore-once'
    state['sender_restore_intended'] = True
    atomic_json(journal, state)
    atomic_json(marker, {'session': state['session']})
    run(['systemctl', '--user', 'start', SENDER_SERVICE])
    expires = time.monotonic() + 6
    while time.monotonic() < expires:
        if service_state()['ActiveState'] == 'active' and not marker.exists():
            state['sender_stop_intended'] = False
            atomic_json(journal, state)
            return
        time.sleep(0.1)
    raise RuntimeError('Restored laptop sender did not acknowledge routing preservation')
