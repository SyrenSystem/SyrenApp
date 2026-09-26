import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from session_selection import OrderedPlaybackState, select_sessions, select_transport


class SessionSelectionTests(unittest.TestCase):
    def setUp(self):
        self.configuration = {'playbackActivated': True, 'groups': [
            {'id': 'group', 'speakerIds': ['speaker', 'other-speaker'],
             'enabledSources': ['spotify', 'laptop', 'casting'], 'muted': False}]}
        self.profiles = [self.profile('first'), self.profile('second'), self.profile('third')]

    def profile(self, identity, pairs=()):
        return {'id': identity, 'sourcePriority': ['spotify', 'laptop', 'casting'],
                'overlap': [{'first': first, 'second': second} for first, second in pairs]}

    def session(self, identity, owner, source, sequence):
        return {'id': identity, 'ownerId': owner, 'source': source, 'claimSequence': sequence,
                'state': 'playing', 'claimed': True, 'eligible': True, 'destination': 'house',
                'transports': [{'id': identity + '-snap', 'kind': 'snapcast',
                                'endpoint': identity, 'available': True}]}

    def select(self, sessions, gains=None, failed=()):
        return select_sessions({'sessions': sessions, 'profiles': self.profiles}, self.configuration,
                               gains if gains is not None else {session['id']: 0.5 for session in sessions}, 'speaker',
                               failed=failed)

    def test_source_order_precedes_claim_age_within_one_person(self):
        sessions = [self.session('music', 'first', 'spotify', 1), self.session('pc', 'first', 'laptop', 100)]
        self.assertEqual(self.select(sessions).selected, ('music',))
        self.profiles[0]['sourcePriority'] = ['laptop', 'spotify', 'casting']
        self.assertEqual(self.select(sessions).selected, ('pc',))

    def test_newest_claim_wins_between_people_regardless_of_refusal(self):
        self.profiles[0] = self.profile('first', [('spotify', 'laptop')])
        sessions = [self.session('music', 'second', 'spotify', 1), self.session('pc', 'first', 'laptop', 2)]
        self.assertEqual(self.select(sessions).selected, ('pc',))
        sessions[0]['claimSequence'] = 3
        self.assertEqual(self.select(sessions).selected, ('music',))

    def test_cross_person_overlap_requires_both_permissions(self):
        sessions = [self.session('music', 'first', 'spotify', 1), self.session('pc', 'second', 'laptop', 2)]
        self.profiles[0] = self.profile('first', [('spotify', 'laptop')])
        self.assertEqual(self.select(sessions).selected, ('pc',))
        self.profiles[1] = self.profile('second', [('laptop', 'spotify')])
        self.assertEqual(self.select(sessions).selected, ('pc', 'music'))

    def test_spotify_can_mix_with_spotify_only_when_enabled(self):
        sessions = [self.session('older', 'first', 'spotify', 1), self.session('newer', 'first', 'spotify', 2)]
        self.assertEqual(self.select(sessions).selected, ('newer',))
        self.profiles[0] = self.profile('first', [('spotify', 'spotify')])
        self.assertEqual(self.select(sessions).selected, ('newer', 'older'))

    def test_three_sessions_must_be_pairwise_compatible(self):
        pairs = [('spotify', 'laptop'), ('laptop', 'casting')]
        self.profiles = [self.profile(identity, pairs) for identity in ('first', 'second', 'third')]
        sessions = [self.session('music', 'first', 'spotify', 3), self.session('pc', 'second', 'laptop', 2),
                    self.session('guide', 'third', 'casting', 1)]
        self.assertEqual(self.select(sessions).selected, ('music', 'pc'))
        sessions[2]['claimSequence'] = 4
        self.assertEqual(self.select(sessions).selected, ('guide', 'pc'))

    def test_zero_gain_does_not_displace_and_movement_does_not_reclaim(self):
        sessions = [self.session('older', 'first', 'spotify', 1), self.session('newer', 'second', 'spotify', 2)]
        original = copy.deepcopy(sessions)
        self.assertEqual(self.select(sessions, {'older': 1, 'newer': 0}).selected, ('older',))
        self.assertEqual(self.select(sessions, {'older': 1, 'newer': 1}).selected, ('newer',))
        self.assertEqual(sessions, original)

    def test_releasing_and_disabling_restore_an_eligible_session(self):
        sessions = [self.session('older', 'first', 'spotify', 1), self.session('newer', 'second', 'laptop', 2)]
        sessions[1].update(claimed=False, eligible=False)
        self.assertEqual(self.select(sessions).selected, ('older',))
        sessions[1].update(claimed=True, eligible=True)
        self.configuration['groups'][0]['enabledSources'] = ['spotify']
        self.assertEqual(self.select(sessions).selected, ('older',))

    def test_speakers_in_one_group_make_independent_decisions(self):
        sessions = [self.session('older', 'first', 'spotify', 1), self.session('newer', 'second', 'spotify', 2)]
        first = self.select(sessions, {'older': 1, 'newer': 0})
        second = select_sessions({'sessions': sessions, 'profiles': self.profiles}, self.configuration,
                                 {'older': 0, 'newer': 1}, 'other-speaker')
        self.assertEqual(first.selected, ('older',))
        self.assertEqual(second.selected, ('newer',))

    def test_group_destination_never_escapes_its_group(self):
        session = self.session('music', 'first', 'spotify', 1)
        session['destination'] = 'another-group'
        self.assertEqual(self.select([session]).receiving, ())

    def test_common_headroom_only_reduces_a_sum_above_one(self):
        self.profiles[0] = self.profile('first', [('spotify', 'laptop')])
        sessions = [self.session('music', 'first', 'spotify', 1), self.session('pc', 'first', 'laptop', 2)]
        self.assertEqual(self.select(sessions, {'music': 0.8, 'pc': 0.8}).gains, {'music': 0.5, 'pc': 0.5})
        self.assertEqual(self.select(sessions, {'music': 0.3, 'pc': 0.2}).gains, {'music': 0.3, 'pc': 0.2})
        self.assertEqual(self.select(sessions[:1], {'music': 0.8}).gains, {'music': 0.8})

    def test_muted_group_never_has_audible_gains(self):
        self.configuration['groups'][0]['muted'] = True
        self.assertEqual(self.select([self.session('music', 'first', 'spotify', 1)]).gains, {})

    def test_paused_spotify_stays_ready_beside_pc(self):
        sessions = [self.session('music', 'first', 'spotify', 1), self.session('pc', 'first', 'laptop', 2)]
        sessions[0].update(state='paused', claimed=False, eligible=False)
        result = self.select(sessions)
        self.assertEqual(result.selected, ('pc',))
        self.assertEqual(set(result.receiving), {'pc', 'music'})

    def test_one_transport_per_session_and_rtp_only_on_its_physical_speaker(self):
        session = self.session('pc', 'first', 'laptop', 1)
        session['transports'].append({'id': 'rtp', 'kind': 'rtp', 'endpoint': 'rtp-path',
                                      'speakerId': 'speaker', 'available': True})
        self.assertEqual(select_transport(session, 'speaker')['id'], 'rtp')
        self.assertEqual(select_transport(session, 'speaker', {'rtp': False})['id'], 'pc-snap')
        self.assertEqual(select_transport(session, 'other-speaker')['id'], 'pc-snap')

    def test_server_eligibility_is_used_without_comparing_clocks(self):
        session = self.session('music', 'first', 'spotify', 1)
        session.update(interruptedAt='1970-01-01T00:00:00Z', lastHeartbeat='2999-01-01T00:00:00Z')
        self.assertEqual(self.select([session]).selected, ('music',))
        session['eligible'] = False
        result = self.select([session])
        self.assertEqual(result.selected, ())
        self.assertEqual(result.reasons, {'music': 'playback unavailable'})

    def test_local_input_failure_hands_over_to_the_next_session(self):
        sessions = [self.session('older', 'first', 'spotify', 1), self.session('newer', 'second', 'spotify', 2)]
        self.assertEqual(self.select(sessions, failed={'newer'}).selected, ('older',))

    def test_ended_sessions_are_left_out_of_reports(self):
        session = self.session('music', 'first', 'spotify', 1)
        ended = dict(self.session('old', 'first', 'spotify', 0), state='ended', eligible=False, transports=[])
        self.assertEqual(set(self.select([ended, session]).reasons), {'music'})
        self.configuration['playbackActivated'] = False
        self.assertEqual(set(self.select([ended, session]).reasons), {'music'})

    def test_waits_for_coordinated_activation(self):
        self.configuration['playbackActivated'] = False
        self.assertEqual(self.select([self.session('music', 'first', 'spotify', 1)]).receiving, ())


class OrderedPlaybackStateTests(unittest.TestCase):
    def test_stale_generations_and_duplicate_revisions_are_rejected(self):
        state = OrderedPlaybackState('house')
        configuration = {'stateId': 'house', 'protocolVersion': 3, 'generation': 2, 'revision': 1}
        self.assertTrue(state.receive('Configuration', configuration))
        self.assertFalse(state.receive('Configuration', configuration))
        self.assertFalse(state.receive('Configuration', dict(configuration, generation=1, revision=100)))
        self.assertFalse(state.receive('Configuration', dict(configuration, stateId='another', generation=3)))

    def test_retained_messages_can_arrive_before_configuration(self):
        state = OrderedPlaybackState('house')
        catalogue = {'protocolVersion': 3, 'stateId': 'house', 'generation': 2, 'revision': 3, 'configurationRevision': 1}
        gains = {'stateId': 'house', 'generation': 2, 'revision': 5, 'configurationRevision': 1, 'catalogueRevision': 3}
        state.receive('Catalogue', catalogue)
        state.receive('Gains', gains)
        state.receive('Configuration', {'stateId': 'house', 'protocolVersion': 3, 'generation': 2, 'revision': 1})
        self.assertTrue(state.coherent())
        state.receive('Configuration', {'stateId': 'house', 'protocolVersion': 3, 'generation': 3, 'revision': 1})
        self.assertFalse(state.coherent())


if __name__ == '__main__':
    unittest.main()
