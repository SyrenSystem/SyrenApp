#!/usr/bin/env python3
"""Create aligned flashes and clicks and inspect recordings of their playback."""

import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile
import wave

import numpy as np


RATE = 48000


def command(arguments):
    return subprocess.check_output(arguments, stderr=subprocess.PIPE)


def click_samples(peak_dbfs=-30):
    coordinates = np.arange(384) / RATE
    phase = 2 * np.pi * (2500 * coordinates + 150000 * coordinates ** 2)
    envelope = np.minimum(1, np.minimum(coordinates / 0.0005, (0.008 - coordinates) / 0.0005))
    return np.sin(phase) * envelope * 10 ** (peak_dbfs / 20)


def make_clip(arguments):
    directory = Path(arguments.output)
    directory.mkdir(parents=True, exist_ok=True)
    duration = arguments.events * 5
    event_times = np.arange(arguments.events) * 5 + 2
    samples = np.zeros(duration * RATE, dtype=np.float32)
    click = click_samples(arguments.peak_dbfs)
    for timestamp in event_times:
        start = int(timestamp * RATE)
        samples[start:start + len(click)] = click
    with tempfile.TemporaryDirectory() as temporary:
        audio_path = Path(temporary) / 'clicks.wav'
        with wave.open(str(audio_path), 'wb') as output:
            output.setnchannels(2)
            output.setsampwidth(2)
            output.setframerate(RATE)
            output.writeframes(np.repeat((samples * 32767).astype('<i2'), 2).tobytes())
        command(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                 '-f', 'lavfi', '-i', f'color=black:s=960x540:r=120:d={duration}',
                 '-i', str(audio_path), '-vf',
                 "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(mod(t,5),2,2.1)'",
                 '-c:v', 'libvpx-vp9', '-lossless', '1', '-deadline', 'realtime', '-cpu-used', '8',
                 '-c:a', 'libopus', '-b:a', '128k', '-ar', str(RATE), '-ac', '2',
                 '-shortest', str(directory / 'flash-click.webm')])
    manifest = {'events_seconds': event_times.tolist(), 'sample_rate': RATE, 'video_fps': 120,
                'audio_peak_dbfs': arguments.peak_dbfs, 'audio_click_ms': 8, 'source_alignment_ms': 0,
                'note': 'Verify the encoded clip with analyze before using it as a reference.'}
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    (directory / 'index.html').write_text('''<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Syren flash and click</title>
<style>body{margin:0;background:#111;color:#eee;font:18px sans-serif;text-align:center}
video{display:block;width:100%;max-height:85vh}p{margin:12px}</style>
<video src="flash-click.webm" controls loop playsinline></video>
<p>Click every five seconds. Source peak: @PEAK_DBFS@ dBFS.</p>
<p>Start at 10% prototype volume, then adjust together in steps of 10.</p>
<p>Use fullscreen for recording. Nothing plays automatically.</p></html>
'''.replace('@PEAK_DBFS@', f'{arguments.peak_dbfs:g}'))
    print(directory / 'index.html')


def media_info(path):
    return json.loads(command(['ffprobe', '-v', 'error', '-show_streams', '-show_format',
                               '-of', 'json', str(path)]))


def match_click(samples, flash_time, window_seconds, minimum_score):
    reference = click_samples().astype(np.float64)
    first = max(0, int((flash_time - window_seconds) * RATE))
    last = min(len(samples), int((flash_time + window_seconds) * RATE))
    window = samples[first:last].astype(np.float64)
    if len(window) < len(reference):
        return None
    window -= np.mean(window)
    transform_size = 1 << (len(window) + len(reference) - 2).bit_length()
    correlation = np.fft.irfft(np.fft.rfft(window, transform_size) *
                              np.fft.rfft(reference[::-1], transform_size), transform_size)
    correlation = correlation[len(reference) - 1:len(window)]
    energy_sum = np.concatenate(([0], np.cumsum(window ** 2)))
    energy = energy_sum[len(reference):] - energy_sum[:-len(reference)]
    scores = np.abs(correlation) / np.sqrt(np.maximum(energy, 1e-16) * np.sum(reference ** 2))
    peak = int(np.argmax(scores))
    score = float(scores[peak])
    if score < minimum_score or np.sqrt(energy[peak] / len(reference)) < 1e-6:
        return None
    return {'click_s': (first + peak) / RATE, 'correlation_score': score}


def analyze(arguments):
    path = Path(arguments.recording)
    information = media_info(path)
    origin = float(information['format'].get('start_time', 0))
    frame_report = json.loads(command(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_frames', '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(path)]))
    frame_times = np.array([float(frame['best_effort_timestamp_time']) - origin
                            for frame in frame_report['frames']])
    crop_filter = f'crop={arguments.roi},' if arguments.roi else ''
    pixels = command(['ffmpeg', '-v', 'error', '-copyts', '-start_at_zero', '-i', str(path),
        '-map', '0:v:0', '-vf', crop_filter + 'scale=1:1:flags=area,format=gray',
        '-fps_mode', 'passthrough', '-f', 'rawvideo', '-'])
    brightness = np.frombuffer(pixels, dtype=np.uint8)
    if len(brightness) != len(frame_times) or len(frame_times) < 2:
        raise ValueError('Frame timestamps do not match decoded frames')
    if np.max(brightness) - np.min(brightness) < 40:
        raise ValueError('Flash contrast is too low; choose an ROI inside the test video')
    bright = brightness > (float(np.max(brightness)) + float(np.min(brightness))) / 2
    transitions = np.flatnonzero(bright & ~np.concatenate(([True], bright[:-1])))
    flash_times = frame_times[transitions]
    retained = np.concatenate(([True], np.diff(flash_times) > 1)) if len(flash_times) else np.array([], dtype=bool)
    flash_times = flash_times[retained]
    event_frame_gaps = np.diff(frame_times)[transitions[retained] - 1]
    audio = command(['ffmpeg', '-v', 'error', '-copyts', '-start_at_zero', '-i', str(path),
        '-map', '0:a:0', '-af', f'aresample={RATE}:async=1:first_pts=0', '-ac', '1',
        '-f', 'f32le', '-'])
    samples = np.frombuffer(audio, dtype='<f4')
    events = []
    rejected = []
    used_clicks = []
    for flash_time in flash_times:
        matched = match_click(samples, flash_time, arguments.window, arguments.minimum_score)
        if matched is None or any(abs(matched['click_s'] - previous) < 1 for previous in used_clicks):
            rejected.append(float(flash_time))
            continue
        used_clicks.append(matched['click_s'])
        events.append(dict(matched, flash_s=float(flash_time),
                           offset_ms=1000 * (matched['click_s'] - flash_time)))
    if not events:
        raise ValueError('No clicks matched; inspect the microphone track and ROI')
    offsets = np.array([event['offset_ms'] for event in events])
    acoustic_ms = arguments.distance / 343 * 1000
    frame_resolution_ms = float(np.percentile(np.diff(frame_times), 95) * 1000)
    maximum_flash_frame_gap_ms = float(np.max(event_frame_gaps) * 1000)
    result = {'recording': str(path.resolve()), 'kind': arguments.kind,
              'distance_m': arguments.distance, 'acoustic_travel_ms': acoustic_ms,
              'frame_resolution_ms': frame_resolution_ms,
              'maximum_flash_frame_gap_ms': maximum_flash_frame_gap_ms,
              'recording_uncertainty_ms': arguments.uncertainty,
              'uncertainty_ms': maximum_flash_frame_gap_ms / 2 + arguments.uncertainty,
              'median_offset_ms': float(np.median(offsets)),
              'p95_offset_ms': float(np.percentile(offsets, 95)),
              'median_acoustic_corrected_ms': float(np.median(offsets) - acoustic_ms),
              'duration_seconds': float(information['format']['duration']),
              'matched_events': len(events), 'rejected_flash_times': rejected, 'events': events,
              'interpretation': 'Positive means sound after picture. Only a phone recording measures the physical screen.'}
    Path(arguments.output).write_text(json.dumps(result, indent=2))
    print(json.dumps({key: value for key, value in result.items() if key != 'events'}, indent=2))


def compare_results(baseline, candidate):
    offsets = np.array([event['offset_ms'] - candidate['acoustic_travel_ms']
                        for event in candidate['events']])
    added = offsets - baseline['median_acoustic_corrected_ms']
    uncertainty = baseline['uncertainty_ms'] + candidate['uncertainty_ms']
    median = float(np.median(added))
    percentile = float(np.percentile(added, 95))
    decision = 'inconclusive'
    if baseline['kind'] != candidate['kind']:
        raise ValueError('Compare recordings made using the same method')
    if min(baseline['matched_events'], candidate['matched_events']) >= 20:
        if median - uncertainty > 30 or percentile - uncertainty > 50:
            decision = 'fail'
        elif median + uncertainty <= 30 and percentile + uncertainty <= 50:
            decision = 'latency pass, stability evidence still required'
    if baseline['rejected_flash_times'] or candidate['rejected_flash_times']:
        decision = 'inconclusive, review rejected events before drawing a conclusion'
    events = candidate['events']
    split = max(1, len(events) // 4)
    drift = float(np.median([event['offset_ms'] for event in events[-split:]]) -
                  np.median([event['offset_ms'] for event in events[:split]]))
    return {'median_added_ms': median, 'p95_added_ms': percentile,
            'added_uncertainty_ms': uncertainty, 'decision': decision,
            'end_minus_beginning_ms': drift,
            'growing_delay_detected': drift > 2 * candidate['uncertainty_ms']}


def compare(arguments):
    baseline = json.loads(Path(arguments.baseline).read_text())
    comparisons = {}
    for recording in arguments.candidates:
        candidate = json.loads(Path(recording).read_text())
        comparisons[recording] = compare_results(baseline, candidate)
    report = {'baseline': arguments.baseline, 'comparisons': comparisons,
              'integration_decision': 'Not approved by this analysis. Complete the two hour listening and failure checklist.'}
    Path(arguments.output).write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    clip_parser = commands.add_parser('clip')
    clip_parser.add_argument('--output', default=str(Path(__file__).parent / 'media'))
    clip_parser.add_argument('--events', type=int, default=24)
    clip_parser.add_argument('--peak-dbfs', type=float, default=-30,
                             help='Click peak from -60 to -6 dBFS; reset receiver volume before using a louder clip')
    analyze_parser = commands.add_parser('analyze')
    analyze_parser.add_argument('recording')
    analyze_parser.add_argument('--output', required=True)
    analyze_parser.add_argument('--kind', choices=['screen-microphone', 'phone', 'source'], required=True)
    analyze_parser.add_argument('--distance', type=float, required=True, help='Speaker to microphone distance in metres')
    analyze_parser.add_argument('--uncertainty', type=float, required=True, help='Recording and detection uncertainty in ms, beyond frame resolution')
    analyze_parser.add_argument('--roi', help='width:height:x:y of the flashing area')
    analyze_parser.add_argument('--window', type=float, default=1.5)
    analyze_parser.add_argument('--minimum-score', type=float, default=0.4)
    compare_parser = commands.add_parser('compare')
    compare_parser.add_argument('--baseline', required=True)
    compare_parser.add_argument('candidates', nargs='+')
    compare_parser.add_argument('--output', required=True)
    arguments = parser.parse_args()
    if arguments.action == 'clip':
        if not 20 <= arguments.events <= 120:
            parser.error('Use 20 to 120 events')
        if not math.isfinite(arguments.peak_dbfs) or not -60 <= arguments.peak_dbfs <= -6:
            parser.error('Use a click peak from -60 to -6 dBFS')
        make_clip(arguments)
    elif arguments.action == 'analyze':
        if (not all(math.isfinite(value) for value in [arguments.distance, arguments.uncertainty, arguments.window])
                or arguments.distance < 0 or arguments.uncertainty < 0 or not 0 < arguments.window < 2.5
                or not 0 < arguments.minimum_score <= 1):
            parser.error('Distances and uncertainty must be nonnegative; window must be under 2.5 seconds')
        analyze(arguments)
    else:
        compare(arguments)


if __name__ == '__main__':
    main()
