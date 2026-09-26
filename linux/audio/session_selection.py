"""Select sessions from profile rules without changing their playback claims."""

from dataclasses import dataclass
import math


SOURCE_ORDER = ('spotify', 'laptop', 'casting')


def permits(profile, first, second):
    return any({pair['first'], pair['second']} == {first, second}
               for pair in profile.get('overlap', []))


def compatible(first, second, profiles):
    first_profile = profiles.get(first['ownerId'], {})
    second_profile = profiles.get(second['ownerId'], {})
    return permits(first_profile, first['source'], second['source']) and (
        first['ownerId'] == second['ownerId'] or
        permits(second_profile, first['source'], second['source']))


def available(session, failed=()):
    # The server decides eligibility, so a Pi with a wrong clock still makes the same choice.
    return session.get('eligible') is True and session['id'] not in failed


def candidates_by_profile(sessions, profiles):
    owners = {}
    for session in sessions:
        owners.setdefault(session['ownerId'], []).append(session)
    candidates = []
    for owner, owned in owners.items():
        order = profiles.get(owner, {}).get('sourcePriority', SOURCE_ORDER)
        priorities = {source: index for index, source in enumerate(order)}
        owned.sort(key=lambda session: (priorities.get(session['source'], len(order)),
                                        -session['claimSequence'], session['id']))
        chosen = []
        for session in owned:
            if all(compatible(session, other, profiles) for other in chosen):
                chosen.append(session)
        candidates.extend(chosen)
    return sorted(candidates, key=lambda session: (-session['claimSequence'], session['id']))


def choose(sessions, profiles):
    selected = []
    for session in candidates_by_profile(sessions, profiles):
        if all(compatible(session, other, profiles) for other in selected):
            selected.append(session)
    return selected


@dataclass(frozen=True)
class Selection:
    selected: tuple
    receiving: tuple
    gains: dict
    reasons: dict


def select_sessions(catalogue, configuration, desired_gains, speaker_id, failed=()):
    profiles = {profile['id']: profile for profile in catalogue.get('profiles', [])}
    group = next((group for group in configuration.get('groups', []) if speaker_id in group['speakerIds']), None)
    sessions = [session for session in catalogue.get('sessions', []) if session['state'] != 'ended']
    eligible = []
    scoped = []
    reasons = {}
    for session in sessions:
        identity = session['id']
        if not group or session['destination'] not in ('house', group['id']):
            reasons[identity] = 'outside destination'
        elif session['source'] not in group['enabledSources']:
            reasons[identity] = 'source disabled'
        else:
            if any(transport.get('available') for transport in session.get('transports', [])):
                scoped.append(session)
            if not available(session, failed):
                reasons[identity] = 'playback unavailable'
                continue
            gain = desired_gains.get(identity, 0)
            if group.get('muted') or not math.isfinite(gain) or gain <= 0:
                reasons[identity] = 'zero desired gain'
            else:
                eligible.append(session)
                reasons[identity] = 'displaced by source priority or a newer incompatible claim'
    selected = choose(eligible, profiles) if configuration.get('playbackActivated') else []
    identities = {session['id'] for session in selected}
    receiving = set(identities)
    fallback = choose([session for session in eligible if session['id'] not in identities], profiles)
    if fallback:
        receiving.add(fallback[0]['id'])
    for source in ('laptop', 'spotify'):
        alternatives = [session for session in scoped if session['source'] == source and session['id'] not in identities]
        if alternatives:
            receiving.add(max(alternatives, key=lambda session: session['claimSequence'])['id'])
    gains = {session['id']: min(1.0, desired_gains[session['id']]) for session in selected}
    total = sum(gains.values())
    if total > 1:
        gains = {identity: gain / total for identity, gain in gains.items()}
    for identity in identities:
        reasons[identity] = 'selected'
    if not configuration.get('playbackActivated'):
        receiving.clear()
        reasons = {session['id']: 'waiting for compatible system activation' for session in sessions}
    return Selection(tuple(session['id'] for session in selected), tuple(sorted(receiving)), gains, reasons)


def select_transport(session, speaker_id, health=None):
    health = health or {}
    transports = [transport for transport in session.get('transports', []) if transport.get('available') and
                  health.get(transport['id'], True) and
                  (transport.get('speakerId') is None or transport['speakerId'] == speaker_id)]
    transports.sort(key=lambda transport: (transport['kind'] != 'rtp', transport['id']))
    return transports[0] if transports else None


class OrderedPlaybackState:
    def __init__(self, state_id):
        self.state_id = state_id
        self.generation = -1
        self.messages = {}
        self.pending = {}

    def receive(self, kind, payload):
        if kind in ('Configuration', 'Catalogue') and payload.get('protocolVersion') != 3:
            return False
        if payload.get('stateId', self.state_id) != self.state_id:
            return False
        generation = payload['generation']
        if generation < self.generation:
            return False
        if kind == 'Configuration' and generation > self.generation:
            if payload.get('protocolVersion') != 3:
                return False
            self.generation = generation
            self.messages.clear()
        elif generation > self.generation:
            previous = self.pending.get(kind)
            if previous is None or (generation, payload['revision']) > (previous['generation'], previous['revision']):
                self.pending[kind] = payload
            return False
        previous = self.messages.get(kind)
        if previous and payload['revision'] <= previous['revision']:
            return False
        self.messages[kind] = payload
        if kind == 'Configuration':
            pending, self.pending = self.pending, {}
            for pending_kind, value in pending.items():
                self.receive(pending_kind, value)
        return True

    def coherent(self):
        if not all(kind in self.messages for kind in ('Configuration', 'Catalogue', 'Gains')):
            return False
        configuration, catalogue, gains = (self.messages[kind] for kind in ('Configuration', 'Catalogue', 'Gains'))
        return configuration['revision'] == catalogue['configurationRevision'] == gains['configurationRevision'] and (
            catalogue['revision'] == gains['catalogueRevision'])
