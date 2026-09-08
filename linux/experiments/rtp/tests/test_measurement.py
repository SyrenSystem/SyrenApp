import copy
import unittest

import numpy as np

from test_lifecycle import load_module


measurement = load_module('rtp_measurement', 'measure.py')
packets = load_module('rtp_packets', 'packet_stats.py')


class MeasurementTests(unittest.TestCase):
    def test_click_detection_recovers_known_delay_in_noise(self):
        samples = np.random.default_rng(3).normal(0, 0.0001, 3 * measurement.RATE)
        first = int(1.025 * measurement.RATE)
        reference = measurement.click_samples()
        samples[first:first + len(reference)] += reference
        match = measurement.match_click(samples, 1, 0.5, 0.25)
        self.assertAlmostEqual(match['click_s'], first / measurement.RATE, places=5)

    def test_silence_is_rejected(self):
        self.assertIsNone(measurement.match_click(np.zeros(3 * measurement.RATE), 1, 0.5, 0.25))

    def test_stronger_click_preserves_detected_onset(self):
        for peak_dbfs in [-30, -18, -12, -6]:
            with self.subTest(peak_dbfs=peak_dbfs):
                samples = np.zeros(3 * measurement.RATE)
                first = int(1.025 * measurement.RATE)
                reference = measurement.click_samples(peak_dbfs)
                samples[first:first + len(reference)] = reference
                match = measurement.match_click(samples, 1, 0.5, 0.4)
                self.assertAlmostEqual(match['click_s'], first / measurement.RATE, places=5)

    def baseline(self):
        return {'kind': 'screen-microphone', 'events': [{'offset_ms': 0}] * 24,
                'acoustic_travel_ms': 0, 'median_acoustic_corrected_ms': 0,
                'uncertainty_ms': 4, 'matched_events': 24, 'rejected_flash_times': []}

    def test_baseline_subtraction_removes_acoustic_difference(self):
        baseline = self.baseline()
        candidate = copy.deepcopy(baseline)
        candidate['events'] = [{'offset_ms': 25}] * 24
        candidate['acoustic_travel_ms'] = 5
        result = measurement.compare_results(baseline, candidate)
        self.assertEqual(result['median_added_ms'], 20)
        self.assertTrue(result['decision'].startswith('latency pass'))

    def test_uncertainty_crossing_threshold_is_inconclusive(self):
        baseline = self.baseline()
        candidate = copy.deepcopy(baseline)
        candidate['events'] = [{'offset_ms': 25}] * 24
        result = measurement.compare_results(baseline, candidate)
        self.assertEqual(result['decision'], 'inconclusive')

    def test_rejected_events_cannot_hide_bad_tail_latency(self):
        baseline = self.baseline()
        candidate = copy.deepcopy(baseline)
        candidate['rejected_flash_times'] = [120]
        result = measurement.compare_results(baseline, candidate)
        self.assertTrue(result['decision'].startswith('inconclusive'))

    def test_packet_wrap_reordering_duplicates_and_loss(self):
        statistics = packets.PacketStatistics()
        for position, sequence in enumerate([65534, 0, 65535, 0, 2]):
            statistics.add(position * 0.0025, 'one', sequence, position * 120, 500)
        result = statistics.result()['streams']['one']
        self.assertEqual(result['duplicates'], 1)
        self.assertEqual(result['reordered'], 1)
        self.assertEqual(result['unseen_sequence_numbers'], 1)


if __name__ == '__main__':
    unittest.main()
