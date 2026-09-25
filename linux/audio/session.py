"""Keep receiver recovery and mute independent of slow graph work."""

import threading
import time

from common import VERSION, deadline, validate_version


STATES = {'idle', 'preparing', 'readyMuted', 'playing', 'recoveringMuted', 'stopping', 'recoveryPending'}


class Session:
    def __init__(self, session, ingress, graph_factory, escalate, clock=time.monotonic):
        self.session = session
        self.ingress = ingress
        self.graph_factory = graph_factory
        self.escalate = escalate
        self.clock = clock
        self.state = 'idle'
        self.generation = 0
        self.muted = None
        self.gain = None
        self.graph = None
        self.graph_healthy = False
        self.health_at = None
        self.graph_started = None
        self.worker_terminated = False
        self.error = None
        self.actions = []
        self.last_heartbeat = clock()
        self.control_connected = True
        self.started = clock()
        self.phase_deadline = self.started + 60
        self.closed = threading.Event()
        self.lifecycle = threading.Lock()
        self.controls = threading.Lock()
        self.state_lock = threading.RLock()
        self.control_cancel = threading.Event()
        self.rebuilding = False
        self.mute_pending = False
        self.mute_requested_at = None
        self.mute_confirmed_at = None

    def transition(self, state, reason):
        if state not in STATES:
            raise ValueError('Unknown receiver state')
        self.state = state
        self.actions.append({'at': self.clock(), 'state': state, 'reason': reason})
        self.actions = self.actions[-64:]

    def status(self):
        with self.state_lock:
            return {'version': VERSION, 'session': self.session, 'generation': self.generation,
                    'state': self.state, 'muted': self.muted, 'percent': self.gain,
                    'shared_output': hasattr(self.graph, 'standby'),
                    'selected_source': getattr(self.graph, 'selected_source', 'rtp'),
                    'output_muted': getattr(self.graph, 'snapcast_muted', None) if getattr(self.graph, 'selected_source', 'rtp') == 'snapcast' else self.muted,
                    'mute_pending': self.mute_pending, 'mute_requested_at': self.mute_requested_at,
                    'mute_confirmed_at': self.mute_confirmed_at, 'worker_terminated': self.worker_terminated,
                    'graph_healthy': self.graph_healthy, 'health_at': self.health_at,
                    'last_heartbeat': self.last_heartbeat, 'control_connected': self.control_connected,
                    'reception': self.ingress.filter.status(), 'error': self.error,
                    'negotiated': {'rate': 48000, 'channels': 2, 'format': 'L16',
                        'packet_ms': 2.5, 'target_ms': self.graph.latency if self.graph else 20,
                        'period_frames': self.graph.period if self.graph else None, 'periods': 3},
                    'recovery_actions': list(self.actions), 'discarded': self.ingress.discarded}

    def start(self):
        with self.state_lock:
            if self.state != 'idle':
                raise RuntimeError('Session already started')
            self.generation += 1
            self.transition('preparing', 'explicit start')
        self.rebuild()

    def rebuild(self):
        with self.lifecycle:
            try:
                with deadline(60, self.closed):
                    self.ingress.close()
                    if self.graph:
                        self.graph.stop()
                        if hasattr(self.graph, 'dispose'):
                            self.graph.dispose()
                    port = self.ingress.prepare()
                    graph = self.graph_factory(port)
                    self.graph = graph
                    graph.start()
                    with self.state_lock:
                        if self.closed.is_set():
                            graph.stop()
                            return
                        self.muted, self.gain = graph.muted, graph.volume
                        self.worker_terminated = False
                        self.graph_healthy = True
                        self.health_at = self.clock()
                        self.graph_started = self.clock()
                        self.ingress.open()
            except Exception as error:
                self.fail('Graph recreation failed: ' + str(error))
            finally:
                self.rebuilding = False

    def kill_graph(self):
        self.ingress.close_gate()
        self.graph_healthy = False
        self.muted = None
        try:
            self.worker_terminated = bool(self.graph and self.graph.stop())
        except Exception:
            self.worker_terminated = False
        if not self.worker_terminated:
            self.escalate()
        return self.worker_terminated

    def mute(self, recovery=False):
        with self.state_lock:
            self.generation += 1
            self.control_cancel.set()
            generation = self.generation
            self.mute_pending = True
            self.muted = None
            self.mute_requested_at = self.clock()
            if recovery:
                self.ingress.close_gate()
        confirmed = False
        acquired = self.controls.acquire(timeout=0.02)
        try:
            if self.graph_started is None:
                # No graph runs yet, and a new one starts muted behind the closed ingress gate, so the mute already holds.
                self.ingress.close_gate()
                confirmed = True
            elif acquired and self.graph and not self.worker_terminated:
                try:
                    with deadline(0.20):
                        getattr(self.graph, 'mute_all', lambda percent: self.graph.set_volume(percent, True))(self.gain if self.gain is not None else 10)
                    confirmed = True
                except Exception as error:
                    self.error = self.error or 'Mute readback failed: ' + str(error)
            if not confirmed:
                self.error = self.error or 'Mute unconfirmed; terminating audio worker'
                self.kill_graph()
            with self.state_lock:
                if generation != self.generation:
                    return self.status()
                if confirmed:
                    self.muted = True
                    self.mute_confirmed_at = self.clock()
                    if self.state == 'playing':
                        self.transition('readyMuted', 'explicit mute confirmed')
                else:
                    self.transition('recoveryPending', self.error)
                    self.closed.set()
                self.mute_pending = False
        finally:
            if acquired:
                self.controls.release()
        return self.status()

    def standby(self, request):
        with self.controls:
            with self.state_lock:
                if (request.get('generation') != self.generation or self.mute_pending
                        or self.state not in ('readyMuted', 'playing') or not hasattr(self.graph, 'standby')):
                    raise ValueError('Stale or unsafe source selection')
                muted = request.get('muted', False)
                if type(muted) is not bool:
                    raise ValueError('Mute must be a boolean')
                self.generation += 1
                self.control_cancel.set()
                generation = self.generation
            try:
                with deadline(2):
                    self.graph.standby(muted)
                with self.state_lock:
                    if generation != self.generation:
                        raise ValueError('Mute invalidated source selection')
                    self.muted = True
                    self.transition('readyMuted', 'Group priority selected Snapcast; RTP remains connected')
            except Exception:
                threading.Thread(target=self.begin_recovery, args=('Source selection failed',), daemon=True).start()
                raise
        return self.status()

    def change_gain(self, request, unmute=False):
        generation = request.get('generation')
        with self.controls:
            with self.state_lock:
                if (request.get('session') != self.session or type(generation) is not int or generation != self.generation
                        or self.mute_pending or self.state not in ('readyMuted', 'playing')):
                    raise ValueError('Stale or unsafe gain request; wait for readyMuted and confirm again')
                if unmute and (not self.control_connected or self.clock() - self.last_heartbeat >= 3
                               or not self.graph_healthy or self.health_at is None
                               or self.clock() - self.health_at > 2 or not self.ingress.filter.stable()):
                    raise ValueError('Current control ownership and stable RTP are required')
                percent = request.get('percent', self.gain)
                if type(percent) is not int or not 0 <= percent <= 100:
                    raise ValueError('Gain must be an integer from 0 to 100')
                muted = False if unmute else self.muted
                cancel = self.control_cancel = threading.Event()
            try:
                with deadline(2, cancel):
                    self.graph.set_volume(percent, muted)
                with self.state_lock:
                    if generation != self.generation or cancel.is_set():
                        raise ValueError('Mute invalidated this request')
                    self.gain, self.muted = percent, muted
                    if unmute:
                        self.transition('playing', 'explicit unmute with current generation')
            except Exception:
                threading.Thread(target=self.begin_recovery, args=('Gain confirmation failed',), daemon=True).start()
                raise
        return self.status()

    def begin_recovery(self, reason):
        with self.state_lock:
            if self.state in ('idle', 'stopping', 'recoveryPending'):
                return
            if self.state == 'recoveringMuted' and (self.graph_started is None or self.rebuilding):
                return
            if self.state == 'preparing' and self.graph_started is None:
                # The first graph is still being built, muted and gated, so there is nothing to recover yet.
                return
            if self.state in ('playing', 'readyMuted'):
                self.phase_deadline = self.clock() + 60
            self.transition('recoveringMuted', reason)
            self.graph_healthy = False
        self.mute(recovery=True)
        if self.closed.is_set():
            return
        self.ingress.close()
        if self.graph:
            self.graph.stop()
        self.graph_started = None

    def fail(self, reason):
        with self.state_lock:
            self.error = reason
            self.transition('recoveryPending', reason)
            self.closed.set()
        self.mute(recovery=True)
        self.kill_graph()

    def stop(self):
        with self.state_lock:
            self.transition('stopping', 'stop requested')
            self.closed.set()
        self.mute(recovery=True)
        with self.lifecycle:
            self.ingress.close()
            if self.graph:
                self.graph.stop()
        self.ingress.running = False

    def tick(self):
        now = self.clock()
        if self.closed.is_set() or self.state == 'idle':
            return
        if now - self.last_heartbeat >= 12:
            self.fail('Control lease expired; explicit start is required')
            return
        if self.ingress.filter.identity_changed:
            self.fail('Sender identity changed; explicit start is required')
            return
        if self.state in ('preparing', 'recoveringMuted') and now >= self.phase_deadline:
            self.fail('Startup or recovery exceeded 60 seconds')
            return
        if not self.control_connected or now - self.last_heartbeat >= 3:
            self.begin_recovery('Authenticated control heartbeat lost')
            return
        received = self.ingress.filter.last_received
        if self.state in ('playing', 'readyMuted') and (received is None or now - received >= 0.25):
            self.begin_recovery('No advancing RTP for 250 ms')
            return
        if self.state in ('preparing', 'recoveringMuted') and received is not None and now - received >= 0.25:
            self.begin_recovery('RTP interrupted while preparing the muted graph')
            return
        if self.state == 'recoveringMuted' and self.graph_started is None and not self.rebuilding:
            self.rebuilding = True
            threading.Thread(target=self.rebuild, daemon=True).start()
            return
        if self.state in ('preparing', 'recoveringMuted') and self.graph_started is not None:
            if now - self.graph_started >= 60:
                self.fail('Recovery reception deadline expired')
            elif self.graph_healthy and self.muted is True and self.ingress.filter.stable():
                self.transition('readyMuted', 'One second of advancing RTP confirmed')

    def request(self, request):
        if request.get('session') != self.session:
            raise ValueError('Session does not own this receiver')
        try:
            validate_version(request)
        except ValueError:
            self.fail('Protocol major version changed during session')
            raise
        action = request['action']
        if action == 'heartbeat':
            self.last_heartbeat = self.clock()
            self.control_connected = True
        elif action == 'disconnect':
            self.control_connected = False
            self.begin_recovery('Authenticated control disconnected')
        elif action == 'mute':
            return self.mute()
        elif action == 'standby':
            return self.standby(request)
        elif action in ('volume', 'unmute'):
            return self.change_gain(request, unmute=action == 'unmute')
        elif action == 'stop':
            self.stop()
        elif action not in ('status', 'diagnostics'):
            raise ValueError('Unknown receiver operation')
        return self.status()
