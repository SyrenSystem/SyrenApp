import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:final_project/models/system_configuration.dart';

import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:final_project/ui/laptop_audio_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> ready({int generation = 1, bool muted = true}) => {
  'version': 1,
  'session': 'session',
  'generation': generation,
  'state': 'readyMuted',
  'muted': muted,
  'percent': 10,
  'graph_healthy': true,
  'preferences': {
    'opt_in': true,
    'pairing': {'name': 'Living room', 'snapclient_id': 'id'},
  },
};

void main() {
  testWidgets('delayed idle poll cannot erase a pending mute', (tester) async {
    final poll = Completer<ProcessResult>();
    final mute = Completer<ProcessResult>();
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        if (request['action'] == 'app-heartbeat') return poll.future;
        if (request['action'] == 'mute') return mute.future;
        return ProcessResult(1, 0, jsonEncode(ready()), '');
      },
    );
    service.attachApp();
    service.rtp = RtpStatus(ready());
    unawaited(service.muteRtp());
    poll.complete(ProcessResult(1, 0, '{"version":1,"state":"idle"}', ''));
    await tester.pump();
    expect(service.muteFeedback, 'Muting');
    expect(service.rtp.session, 'session');
    mute.complete(ProcessResult(1, 0, jsonEncode(ready(generation: 2)), ''));
    await tester.pump();
    service.dispose();
  });

  test('versioned requests include session and recovery generation', () async {
    final requests = <Map<String, dynamic>>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request);
        return ProcessResult(1, 0, jsonEncode(ready()), '');
      },
    );
    service.rtp = RtpStatus(ready());
    await service.unmuteRtp();
    expect(requests.single, {
      'version': 1,
      'action': 'unmute',
      'session': 'session',
      'generation': 1,
    });
  });

  testWidgets(
    'mute shows Muting then unconfirmed without optimistic confirmation',
    (tester) async {
      final completion = Completer<ProcessResult>();
      final service = LocalAudioService(
        available: true,
        runner: (executable, arguments) async {
          if (arguments.first != 'rtp') {
            return ProcessResult(1, 0, 'disabled', '');
          }
          final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
          if (request['action'] == 'mute') return completion.future;
          return ProcessResult(1, 0, jsonEncode(ready()), '');
        },
      );
      service.rtp = RtpStatus(ready(muted: false));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [localAudioServiceProvider.overrideWith((ref) => service)],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SpeakerLaptopAudio(
                  receiver: SnapClientInfo(id: 'id', name: 'Living room'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      unawaited(service.muteRtp());
      await tester.pump();
      expect(find.text('Muting'), findsOneWidget);
      expect(service.canUnmute, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Mute unconfirmed'), findsOneWidget);
      expect(service.canUnmute, isFalse);
      completion.complete(
        ProcessResult(1, 0, jsonEncode(ready(generation: 2)), ''),
      );
      await tester.pump();
      await tester.pump();
      expect(service.rtp.muted, isTrue);
      expect(service.muteFeedback, isNull);
      expect(find.text('Muted'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('old generation cannot confirm a new mute', (tester) async {
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async =>
          ProcessResult(1, 0, jsonEncode(ready()), ''),
    );
    service.rtp = RtpStatus(ready());
    await service.muteRtp();
    expect(service.muteFeedback, 'Muting');
    await tester.pump(const Duration(seconds: 1));
    expect(service.muteFeedback, 'Mute unconfirmed');
    expect(service.canUnmute, isFalse);
    service.dispose();
  });

  testWidgets('startup and preference never start playback automatically', (
    tester,
  ) async {
    final requests = <String>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        return ProcessResult(
          1,
          0,
          jsonEncode({
            'version': 1,
            'state': 'idle',
            'preferences': {'opt_in': true},
          }),
          '',
        );
      },
    );
    service.attachApp();
    await tester.pump(const Duration(seconds: 2));
    expect(requests, isNot(contains('start')));
    service.dispose();
    await tester.pump();
    expect(requests, contains('close'));
  });

  test('protocol mismatch is actionable', () async {
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async =>
          ProcessResult(1, 0, '{"version":2}', ''),
    );
    await expectLater(service.rtpRequest('preflight'), throwsStateError);
  });

  testWidgets('mute remains available while a lifecycle operation is busy', (
    tester,
  ) async {
    final blocked = Completer<ProcessResult>();
    final requests = <String>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        if (arguments.first != 'rtp') {
          return ProcessResult(1, 0, 'disabled', '');
        }
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        if (request['action'] == 'volume') return blocked.future;
        return ProcessResult(1, 0, jsonEncode(ready(generation: 2)), '');
      },
    );
    service.rtp = RtpStatus(ready());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localAudioServiceProvider.overrideWith((ref) => service)],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SpeakerLaptopAudio(
                receiver: SnapClientInfo(id: 'id', name: 'Living room'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    unawaited(service.setRtpVolume(20));
    await tester.pump();
    unawaited(service.muteRtp());
    await tester.pump();
    expect(requests, contains('mute'));
    blocked.complete(ProcessResult(1, 0, jsonEncode(ready()), ''));
    await tester.pump();
    expect(service.rtp.generation, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
