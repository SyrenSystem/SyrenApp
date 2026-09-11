import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/services/group_audio_coordinator.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

class AudioRig {
  late Process receiver;
  late StreamIterator<String> responses;
  late LocalAudioService audio;
  late GroupAudioCoordinator coordinator;
  Future<void> pending = Future.value();
  final requests = <String>[];
  final errors = StringBuffer();
  List<String> priority = ['spotify', 'laptop'];
  bool spotify = true;
  bool laptop = true;
  bool muted = false;
  bool online = true;
  double master = 80;
  double speaker = 50;
  double source = 100;
  String groupId = 'group';
  Completer<void>? volumeEntered;
  Completer<void>? volumeRelease;

  SystemConfiguration get configuration => SystemConfiguration(
    stateId: 'state',
    revision: 1,
    speakers: [
      ConfiguredSpeaker(
        id: 'speaker',
        name: 'Speaker',
        snapClientId: 'receiver',
        sensorId: null,
        fullVolumeDistance: 1000,
        muteDistance: 5000,
        level: speaker,
        calibrated: true,
      ),
    ],
    groups: [
      PlaybackGroup(
        id: groupId,
        name: 'Group',
        speakerIds: ['speaker'],
        sourcePriority: priority,
        sourceLevels: {'laptop': source},
        volumeMode: 'manual',
        masterVolume: master,
        muted: muted,
      ),
    ],
    sources: const [],
  );

  Future<void> start() async {
    receiver = await Process.start('python3', [
      'test/support/audio_receiver.py',
    ]);
    receiver.stderr.transform(utf8.decoder).listen(errors.write);
    responses = StreamIterator(
      receiver.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    audio = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        final action = request['action'] as String;
        requests.add(action);
        if (action == 'volume' && volumeEntered != null) {
          final release = volumeRelease!;
          volumeEntered!.complete();
          volumeEntered = null;
          await release.future;
        }
        final result = Completer<ProcessResult>();
        pending = pending.then((_) async {
          try {
            receiver.stdin.writeln(arguments[1]);
            await receiver.stdin.flush();
            if (!await responses.moveNext()) {
              throw StateError('Receiver exited: $errors');
            }
            result.complete(
              ProcessResult(receiver.pid, 0, responses.current, ''),
            );
          } catch (error, stack) {
            result.completeError(error, stack);
          }
        });
        return result.future.timeout(const Duration(seconds: 5));
      },
    );
    coordinator = GroupAudioCoordinator(
      audio: audio,
      configuration: () => configuration,
      runtime: () => SystemRuntime(
        onlineSnapClients: const [],
        sources: [
          AudioSourceStatus(id: 'spotify', active: spotify),
          const AudioSourceStatus(id: 'laptop', active: false),
        ],
      ),
      online: () => online,
      desktopActive: () async => laptop,
    );
    await audio.refreshRtp();
    await refresh();
  }

  Future<void> refresh() => coordinator.refresh();

  Future<void> enable() async {
    await audio.enablePlayback(
      groupVolume: master,
      speakerLevel: speaker,
      sourceLevel: source,
      muted: muted,
    );
    await settle();
  }

  Future<void> settle() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (audio.enablingPlayback || audio.rtp.state == 'preparing') {
      if (DateTime.now().isAfter(deadline)) {
        fail('Playback did not settle: ${audio.rtp.data}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await pending;
    await audio.refreshRtp();
    expect(audio.rtpError, isNull);
  }

  void expectSelection({String? reason}) {
    expect(audio.rtpError, isNull, reason: reason);
    final laptopWins =
        priority.contains('laptop') &&
        (!spotify ||
            !priority.contains('spotify') ||
            (laptop &&
                priority.indexOf('laptop') < priority.indexOf('spotify')));
    expect(
      audio.rtp.state,
      laptopWins && !muted ? 'playing' : 'readyMuted',
      reason: reason,
    );
    if (!muted) {
      expect(
        audio.rtp.data['selected_source'],
        laptopWins ? 'rtp' : 'snapcast',
        reason: reason,
      );
    }
    expect(audio.rtp.outputMuted, muted, reason: reason);
    if (laptopWins) {
      expect(
        audio.rtp.percent,
        (master * speaker * source / 10000).round(),
        reason: reason,
      );
    }
    expect(audio.rtp.data['fixture']['graphs'], 1, reason: reason);
    expect(audio.rtp.data['fixture']['stops'], 0, reason: reason);
    expect(audio.playbackRequested, isTrue, reason: reason);
  }

  Future<void> dispose() async {
    volumeRelease?.complete();
    coordinator.dispose();
    audio.dispose();
    await pending;
    await receiver.stdin.close();
    await receiver.exitCode.timeout(const Duration(seconds: 5));
    await responses.cancel();
    expect(errors.toString(), isEmpty);
  }
}

void main() {
  late AudioRig rig;
  setUp(() async {
    rig = AudioRig();
    await rig.start();
  });
  tearDown(() => rig.dispose());

  test(
    'idle laptop keeps the production RTP branch ready for short sounds',
    () async {
      rig.spotify = false;
      rig.laptop = false;
      await rig.refresh();
      await rig.enable();
      expect(rig.audio.rtp.state, 'playing');
      expect(rig.audio.rtp.data['selected_source'], 'rtp');
      expect(rig.audio.rtp.muted, isFalse);
      final requestsBeforeSound = List<String>.of(rig.requests);
      rig.laptop = true;
      await rig.refresh();
      rig.laptop = false;
      await rig.refresh();
      expect(rig.requests, requestsBeforeSound);
      expect(rig.audio.rtp.state, 'playing');
      expect(rig.audio.rtp.data['fixture']['graphs'], 1);
      expect(rig.audio.rtp.data['fixture']['stops'], 0);
    },
  );

  test(
    'priority and mute matrix uses the production receiver without restarts',
    () async {
      await rig.enable();
      for (final priority in [
        ['spotify', 'laptop'],
        ['laptop', 'spotify'],
        ['spotify'],
        ['laptop'],
      ]) {
        for (final spotify in [true, false]) {
          for (final laptop in [true, false]) {
            for (final muted in [true, false]) {
              rig.priority = priority;
              rig.spotify = spotify;
              rig.laptop = laptop;
              rig.muted = muted;
              await rig.refresh();
              rig.expectSelection(
                reason:
                    '$priority spotify=$spotify laptop=$laptop muted=$muted',
              );
            }
          }
        }
      }
    },
  );

  test(
    '200 seeded setting and source transitions converge in one refresh',
    () async {
      await rig.enable();
      final random = Random(904119);
      for (var index = 0; index < 200; index++) {
        rig.spotify = random.nextBool();
        rig.laptop = random.nextBool();
        rig.muted = random.nextBool();
        rig.priority = random.nextBool()
            ? ['spotify', 'laptop']
            : ['laptop', 'spotify'];
        rig.master = random.nextInt(101).toDouble();
        rig.speaker = random.nextInt(101).toDouble();
        rig.source = random.nextInt(101).toDouble();
        await rig.refresh();
        rig.expectSelection(reason: 'seed=904119 step=$index');
      }
    },
  );

  test('unchanged settings issue no transport or gain commands', () async {
    rig.spotify = false;
    await rig.refresh();
    await rig.enable();
    rig.requests.clear();
    for (var index = 0; index < 20; index++) {
      await rig.refresh();
    }
    expect(rig.requests, isEmpty);
    rig.expectSelection();
  });

  test(
    'initial group mute silences both paths before startup completes',
    () async {
      rig.spotify = false;
      rig.muted = true;
      await rig.refresh();
      await rig.enable();
      rig.expectSelection();
      expect(rig.requests, isNot(contains('unmute')));
    },
  );

  test(
    'volume edited during startup is applied before the first unmute',
    () async {
      rig.spotify = false;
      await rig.refresh();
      final entered = rig.volumeEntered = Completer<void>();
      rig.volumeRelease = Completer<void>();
      await rig.audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await entered.future;
      rig.master = 20;
      await rig.refresh();
      rig.volumeRelease!.complete();
      rig.volumeRelease = null;
      await rig.settle();
      rig.expectSelection();
      final writes = rig.audio.rtp.data['fixture']['writes'] as List;
      final audible = writes.where(
        (write) => write['node'] == 1 && write['muted'] == false,
      );
      expect(audible, hasLength(1));
      expect(audible.single['volume'], .1);
    },
  );

  test(
    'moving the paired speaker to another group applies its volume',
    () async {
      rig.spotify = false;
      await rig.refresh();
      await rig.enable();
      rig.groupId = 'other-group';
      rig.master = 20;
      await rig.refresh();
      rig.expectSelection();
    },
  );

  test('mute arriving during startup gain never permits an unmute', () async {
    rig.spotify = false;
    await rig.refresh();
    final entered = rig.volumeEntered = Completer<void>();
    rig.volumeRelease = Completer<void>();
    await rig.audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await entered.future;
    rig.muted = true;
    await rig.refresh();
    rig.volumeRelease!.complete();
    rig.volumeRelease = null;
    await rig.settle();
    expect(rig.requests, isNot(contains('unmute')));
    rig.expectSelection();
  });

  test(
    'Spotify arriving during startup gain selects standby immediately',
    () async {
      rig.spotify = false;
      await rig.refresh();
      final entered = rig.volumeEntered = Completer<void>();
      rig.volumeRelease = Completer<void>();
      await rig.audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await entered.future;
      rig.spotify = true;
      await rig.refresh();
      rig.volumeRelease!.complete();
      rig.volumeRelease = null;
      await rig.settle();
      expect(rig.requests, isNot(contains('unmute')));
      rig.expectSelection();
    },
  );

  test(
    'disable invalidates a blocked gain and cannot resurrect playback',
    () async {
      await rig.enable();
      final entered = rig.volumeEntered = Completer<void>();
      rig.volumeRelease = Completer<void>();
      rig.spotify = false;
      rig.master = 100;
      final handoff = rig.refresh();
      await entered.future;
      await rig.audio.stopRtp();
      rig.volumeRelease!.complete();
      rig.volumeRelease = null;
      await handoff;
      await rig.refresh();
      expect(rig.audio.rtp.state, 'idle');
      expect(rig.audio.playbackRequested, isFalse);
      expect(rig.requests.where((action) => action == 'start'), hasLength(1));
      expect(rig.requests, isNot(contains('unmute')));
    },
  );

  test('recovery returns to the current winner with saved gain', () async {
    await rig.enable();
    await rig.audio.rtpRequest('fixture-recover');
    await rig.audio.refreshRtp();
    await rig.refresh();
    expect(rig.audio.rtp.data['selected_source'], 'snapcast');
    rig.spotify = false;
    await rig.refresh();
    expect(rig.audio.rtp.state, 'playing');
    expect(rig.audio.rtp.percent, 40);
    expect(rig.audio.rtp.data['fixture']['starts'], 1);
    expect(rig.audio.rtp.data['fixture']['graphs'], 2);
  });

  test(
    'repeated explicit disable and enable never reuses a stale session',
    () async {
      for (var index = 1; index <= 12; index++) {
        rig.spotify = index.isEven;
        await rig.refresh();
        await rig.enable();
        expect(rig.audio.rtp.session, '$index');
        expect(rig.audio.rtp.state, rig.spotify ? 'readyMuted' : 'playing');
        await rig.audio.stopRtp();
        await rig.refresh();
        expect(rig.audio.rtp.state, 'idle');
        expect(rig.audio.playbackRequested, isFalse);
      }
    },
  );
}
