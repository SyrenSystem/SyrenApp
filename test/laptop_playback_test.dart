import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:final_project/ui/laptop_audio_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> status(
  String state, {
  int generation = 1,
  int percent = 10,
}) => {
  'version': 1,
  'state': state,
  'session': state == 'idle' ? null : 'session',
  'generation': generation,
  'percent': percent,
  'muted': state != 'playing',
  'graph_healthy': true,
  'preferences': {
    'opt_in': true,
    'pairing': {'snapclient_id': 'speaker', 'name': 'Living room'},
  },
};

ProcessResult response(Map<String, dynamic> value) =>
    ProcessResult(1, 0, jsonEncode(value), '');

void main() {
  test('lowering volume reaches the target in one confirmed command', () async {
    final levels = <int>[];
    final service = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        levels.add(request['percent'] as int);
        return response(status('playing', percent: levels.last));
      },
    );
    addTearDown(service.dispose);
    service.rtp = RtpStatus(status('playing', percent: 90));
    await service.setPlaybackVolume(5);
    expect(levels, [5]);
    expect(service.rtp.percent, 5);
  });

  testWidgets('idle laptop stays playing unless another source has priority', (
    tester,
  ) async {
    final requests = <String>[];
    var remote = {
      ...status('playing', percent: 100),
      'selected_source': 'rtp',
      'output_muted': false,
    };
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        if (request['action'] == 'standby') {
          remote = {
            ...remote,
            'state': 'readyMuted',
            'muted': true,
            'selected_source': 'snapcast',
          };
        }
        if (request['action'] == 'unmute') {
          remote = {
            ...remote,
            'state': 'playing',
            'muted': false,
            'selected_source': 'rtp',
          };
        }
        return response(remote);
      },
    );
    service.rtp = RtpStatus(remote);
    service.playbackRequested = true;

    Future<void> follow({
      bool spotifyActive = false,
      bool includeLaptop = true,
    }) => service.followGroupPriority(
      configuration: SystemConfiguration(
        stateId: 'state',
        revision: 1,
        speakers: const [
          ConfiguredSpeaker(
            id: 'configured',
            name: 'Living room',
            snapClientId: 'speaker',
            sensorId: null,
            fullVolumeDistance: 1000,
            muteDistance: 5000,
            level: 100,
            calibrated: true,
          ),
        ],
        groups: [
          PlaybackGroup(
            id: 'group',
            name: 'Default',
            speakerIds: const ['configured'],
            sourcePriority: ['spotify', if (includeLaptop) 'laptop'],
            volumeMode: 'manual',
            masterVolume: 100,
            muted: false,
          ),
        ],
        sources: const [],
      ),
      runtime: SystemRuntime(
        onlineSnapClients: const [],
        sources: [AudioSourceStatus(id: 'spotify', active: spotifyActive)],
      ),
      desktopActive: false,
    );

    await follow();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localAudioServiceProvider.overrideWith((ref) => service)],
        child: const MaterialApp(
          home: Scaffold(
            body: SpeakerLaptopAudio(
              receiver: SnapClientInfo(id: 'speaker', name: 'Living room'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Playing laptop audio'), findsOneWidget);
    expect(find.text('Connected · Following group priority'), findsNothing);
    expect(requests, isEmpty);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    await follow(spotifyActive: true);
    await tester.pump();
    expect(find.text('Connected · Following group priority'), findsOneWidget);
    expect(find.text('Playing laptop audio'), findsNothing);

    await follow();
    await tester.pump();
    expect(find.text('Playing laptop audio'), findsOneWidget);

    await follow(includeLaptop: false);
    await tester.pump();
    expect(find.text('Playing laptop audio'), findsNothing);
    expect(find.text('Connected · Following group priority'), findsOneWidget);
    expect(requests, ['standby', 'unmute', 'standby']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('startup errors replace the connecting label', (tester) async {
    final service = LocalAudioService(
      available: true,
      runner: (_, _) async => response(status('idle')),
    );
    service.rtp = RtpStatus({
      ...status('preparing'),
      'error': 'Receiver control failed',
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localAudioServiceProvider.overrideWith((ref) => service)],
        child: const MaterialApp(
          home: Scaffold(
            body: SpeakerLaptopAudio(
              receiver: SnapClientInfo(id: 'speaker', name: 'Living room'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connecting...'), findsNothing);
    expect(find.text('Connection needs attention'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pending recovery can be stopped with the existing switch', (
    tester,
  ) async {
    final requests = <String>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        return response(status('idle'));
      },
    );
    service.rtp = RtpStatus(status('recoveryPending'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localAudioServiceProvider.overrideWith((ref) => service)],
        child: const MaterialApp(
          home: Scaffold(
            body: SpeakerLaptopAudio(
              receiver: SnapClientInfo(id: 'speaker', name: 'Living room'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Connection needs attention'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.byType(TextButton), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(requests, ['stop']);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one switch enables playback only after initial readiness', (
    tester,
  ) async {
    var remote = status('idle');
    final requests = <String>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        if (request['action'] == 'start') remote = status('preparing');
        if (request['action'] == 'volume') {
          expectSync(remote['muted'], isTrue);
          remote = status('readyMuted', percent: request['percent'] as int);
        }
        if (request['action'] == 'unmute') {
          expectSync(remote['percent'], 40);
          remote = status('playing', percent: 40);
        }
        if (request['action'] == 'stop') remote = status('idle');
        return response(remote);
      },
    );
    service.rtp = RtpStatus(remote);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localAudioServiceProvider.overrideWith((ref) => service),
          systemConfigurationProvider.overrideWith(
            (ref) => const SystemConfiguration(
              stateId: 'state',
              revision: 1,
              speakers: [
                ConfiguredSpeaker(
                  id: 'configured',
                  name: 'Living room',
                  snapClientId: 'speaker',
                  sensorId: null,
                  fullVolumeDistance: 1000,
                  muteDistance: 5000,
                  level: 50,
                  calibrated: true,
                ),
              ],
              groups: [
                PlaybackGroup(
                  id: 'group',
                  name: 'Default',
                  speakerIds: ['configured'],
                  sourcePriority: ['laptop'],
                  volumeMode: 'manual',
                  masterVolume: 80,
                  muted: false,
                ),
              ],
              sources: [],
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SpeakerLaptopAudio(
              receiver: SnapClientInfo(id: 'speaker', name: 'Living room'),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SwitchListTile), findsOneWidget);
    for (final label in [
      'Preflight',
      'Mute',
      'Unmute',
      'Start muted at 10%',
      'Pair receiver',
      'Volume up 10%',
    ]) {
      expect(find.text(label), findsNothing);
    }
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('Connecting...'), findsOneWidget);
    expect(requests, isNot(contains('unmute')));
    remote = status('readyMuted');
    await service.refreshRtp();
    await tester.pump();
    expect(
      requests.where((action) => action == 'unmute'),
      hasLength(1),
      reason: '$requests ${service.rtpError} ${service.rtp.data}',
    );
    expect(find.text('Playing laptop audio'), findsOneWidget);
    expect(service.rtp.percent, 40);
    expect(requests.where((action) => action == 'volume'), hasLength(3));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(requests.last, 'stop');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recovery cannot reuse the enable gesture to unmute', (
    tester,
  ) async {
    var remote = status('idle');
    final requests = <String>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        if (request['action'] == 'start') remote = status('preparing');
        return response(remote);
      },
    );
    await service.enablePlayback(groupVolume: 80, speakerLevel: 50);
    remote = status('readyMuted', generation: 2);
    await service.refreshRtp();
    await tester.pump();
    expect(requests, isNot(contains('unmute')));
    expect(service.enablingPlayback, isFalse);
    expect(
      service.resumePending,
      isTrue,
      reason: 'the switch stays on so the coordinator confirms volume again',
    );
    service.dispose();
  });

  testWidgets('a paused laptop session is described by its output state', (
    tester,
  ) async {
    var remote = status('idle');
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        if (request['action'] == 'start') remote = status('preparing');
        return response(remote);
      },
    );
    remote = {
      ...status('readyMuted'),
      'selected_source': 'snapcast',
      'output_muted': false,
    };
    await service.refreshRtp();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localAudioServiceProvider.overrideWith((ref) => service)],
        child: const MaterialApp(
          home: Scaffold(
            body: SpeakerLaptopAudio(
              receiver: SnapClientInfo(id: 'speaker', name: 'Living room'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Paused · Snapcast selected'), findsOneWidget);
    expect(find.text('Muted'), findsNothing);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    remote = {...status('readyMuted'), 'output_muted': true};
    await service.refreshRtp();
    await tester.pump();
    expect(find.text('Muted'), findsOneWidget);

    remote = status('idle');
    await service.refreshRtp();
    await service.enablePlayback(groupVolume: 80, speakerLevel: 50);
    remote = {
      ...status('readyMuted', generation: 2),
      'selected_source': 'snapcast',
      'output_muted': false,
    };
    await service.refreshRtp();
    await tester.pump();
    expect(service.resumePending, isTrue);
    expect(find.text('Reconnected · Resuming'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('turning off cancels a delayed start response', (tester) async {
    final started = Completer<ProcessResult>();
    final requests = <String>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        if (request['action'] == 'start') return started.future;
        return response(status('idle'));
      },
    );
    final enabling = service.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await tester.pump();
    await service.stopRtp();
    started.complete(response(status('readyMuted')));
    await enabling;
    expect(requests, isNot(contains('unmute')));
    expect(requests.last, 'stop');
    service.dispose();
  });

  for (final interruption in ['stop', 'mute', 'recovery', 'gain failure']) {
    testWidgets('startup gain confirmation cannot unmute after $interruption', (
      tester,
    ) async {
      final gain = Completer<ProcessResult>();
      final requests = <String>[];
      var remote = status('idle');
      final service = LocalAudioService(
        available: true,
        runner: (executable, arguments) async {
          final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
          requests.add(request['action'] as String);
          if (request['action'] == 'start') remote = status('preparing');
          if (request['action'] == 'volume') return gain.future;
          if (request['action'] == 'stop') remote = status('idle');
          if (request['action'] == 'mute') {
            remote = status('readyMuted', generation: 2);
          }
          return response(remote);
        },
      );
      await service.enablePlayback(groupVolume: 60, speakerLevel: 50);
      remote = status('readyMuted');
      await service.refreshRtp();
      await tester.pump();
      expect(requests, contains('volume'));
      expect(requests, isNot(contains('unmute')));
      if (interruption == 'stop') await service.stopRtp();
      if (interruption == 'mute') await service.muteRtp();
      if (interruption == 'recovery') {
        remote = status('readyMuted', generation: 2);
        await service.refreshRtp();
      }
      gain.complete(
        interruption == 'gain failure'
            ? ProcessResult(
                1,
                1,
                '{"version":1,"error":"Gain readback failed"}',
                '',
              )
            : response(status('readyMuted', percent: 20)),
      );
      await tester.pump();
      expect(requests, isNot(contains('unmute')));
      if (interruption == 'gain failure') {
        expect(service.rtpError, contains('Gain readback failed'));
      }
      service.dispose();
    });
  }

  for (final muted in [true, false]) {
    testWidgets('startup honors zero volume and configured mute $muted', (
      tester,
    ) async {
      final requests = <String>[];
      var remote = status('idle');
      final service = LocalAudioService(
        available: true,
        runner: (executable, arguments) async {
          final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
          requests.add(request['action'] as String);
          if (request['action'] == 'start') remote = status('preparing');
          if (request['action'] == 'volume') {
            remote = status('readyMuted', percent: request['percent'] as int);
          }
          if (request['action'] == 'unmute') {
            expectSync(remote['percent'], 0);
            remote = status('playing', percent: 0);
          }
          return response(remote);
        },
      );
      await service.enablePlayback(
        groupVolume: 0,
        speakerLevel: 70,
        muted: muted,
      );
      remote = status('readyMuted');
      await service.refreshRtp();
      await tester.pump();
      expect(service.rtp.percent, 0);
      expect(requests.contains('unmute'), !muted);
      expect(service.enablingPlayback, isFalse);
      service.dispose();
    });
  }

  testWidgets('slider target uses confirmed gain steps', (tester) async {
    final levels = <int>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        if (request['action'] == 'volume') {
          levels.add(request['percent'] as int);
          return response(status('playing', percent: levels.last));
        }
        return response(status('idle'));
      },
    );
    service.rtp = RtpStatus(status('playing'));
    await service.setPlaybackVolume(45);
    expect(levels, [20, 30, 40, 45]);
    expect(service.rtp.percent, 45);
    service.dispose();
  });
}
