import 'dart:async';
import 'dart:convert';
import 'package:final_project/services/group_audio_coordinator.dart';
import 'dart:io';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

SystemConfiguration configuration(
  List<String> priority, {
  bool muted = false,
  double master = 80,
}) => SystemConfiguration(
  stateId: 'state',
  revision: 1,
  speakers: const [
    ConfiguredSpeaker(
      id: 'speaker',
      name: 'Speaker',
      snapClientId: 'receiver',
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
      name: 'Group',
      speakerIds: const ['speaker'],
      sourcePriority: priority,
      volumeMode: 'manual',
      masterVolume: master,
      muted: muted,
    ),
  ],
  sources: const [],
);

void main() {
  late LocalAudioService audio;
  late Map<String, dynamic> remote;
  late List<String> requests;
  var sessionNumber = 0;
  var confirmVolume = true;
  var failHeartbeat = false;
  var supersedeVolume = false;

  setUp(() {
    requests = [];
    sessionNumber = 0;
    confirmVolume = true;
    failHeartbeat = false;
    supersedeVolume = false;
    remote = {
      'version': 1,
      'state': 'idle',
      'session': null,
      'generation': 1,
      'percent': 10,
      'muted': true,
      'graph_healthy': true,
      'preferences': {
        'pairing': {'snapclient_id': 'receiver'},
      },
    };
    audio = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        final action = request['action'] as String;
        requests.add(action);
        if (action == 'app-heartbeat' && failHeartbeat) {
          throw StateError('controller unavailable');
        }
        switch (action) {
          case 'start':
            remote = {
              ...remote,
              'state': 'readyMuted',
              'session': 'session${++sessionNumber}',
              'generation': 1,
              'muted': true,
              'percent': 10,
            };
          case 'standby':
            remote = {
              ...remote,
              'state': 'readyMuted',
              'muted': true,
              'selected_source': 'snapcast',
              'generation': (remote['generation'] as int) + 1,
            };
          case 'stop':
            remote = {
              ...remote,
              'state': 'idle',
              'session': null,
              'muted': true,
            };
          case 'volume':
            if (confirmVolume) {
              remote = {...remote, 'percent': request['percent']};
            }
            if (supersedeVolume) {
              // A slider release lands while this step is in flight and takes over the volume intent.
              supersedeVolume = false;
              unawaited(
                audio.setPlaybackLevels(groupVolume: 20, speakerLevel: 50),
              );
            }
          case 'mute':
            remote = {
              ...remote,
              'state': remote['state'] == 'playing'
                  ? 'readyMuted'
                  : remote['state'],
              'muted': true,
              'generation': (remote['generation'] as int) + 1,
            };
          case 'unmute':
            remote = {
              ...remote,
              'state': 'playing',
              'muted': false,
              'selected_source': 'rtp',
            };
        }
        return ProcessResult(1, 0, jsonEncode(remote), '');
      },
    );
    audio.rtp = RtpStatus(remote);
  });
  tearDown(() => audio.dispose());

  Future<void> follow(
    List<String> priority, {
    bool spotify = true,
    bool laptop = true,
    bool muted = false,
    double master = 80,
  }) async {
    await audio.followGroupPriority(
      configuration: configuration(priority, muted: muted, master: master),
      runtime: SystemRuntime(
        onlineSnapClients: const [],
        sources: [
          AudioSourceStatus(id: 'spotify', active: spotify),
          const AudioSourceStatus(id: 'laptop', active: false),
        ],
      ),
      desktopActive: laptop,
    );
    await Future<void>.delayed(Duration.zero);
  }

  test('priority observation never starts playback without enabling', () async {
    await follow(['laptop', 'spotify']);
    expect(requests, isEmpty);
  });

  test('Spotify priority waits then restores laptop at saved volume', () async {
    await follow(['spotify', 'laptop']);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    expect(audio.waitingForPriority, isTrue);
    expect(requests, isNot(contains('unmute')));
    await follow(['spotify', 'laptop'], spotify: false);
    expect(audio.rtp.state, 'playing');
    expect(audio.rtp.percent, 40);
    await follow(['spotify', 'laptop']);
    expect(audio.rtp.state, 'readyMuted');
    expect(audio.waitingForPriority, isTrue);
    await follow(['spotify', 'laptop'], spotify: false);
    expect(requests.where((action) => action == 'start'), hasLength(1));
    expect(requests, isNot(contains('stop')));
  });

  test('laptop first wins while active and yields when paused', () async {
    await follow(['laptop', 'spotify']);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await follow(['laptop', 'spotify']);
    expect(audio.rtp.state, 'playing');
    await follow(['laptop', 'spotify'], laptop: false);
    expect(audio.rtp.state, 'readyMuted');
    await follow(['laptop', 'spotify']);
    expect(audio.rtp.state, 'playing');
  });

  test(
    'laptop stays selected between sounds when other sources are idle',
    () async {
      await follow(['spotify', 'laptop'], spotify: false, laptop: false);
      await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(audio.rtp.state, 'playing');
      expect(audio.waitingForPriority, isFalse);
      final requestsBeforePause = List<String>.of(requests);
      await follow(['spotify', 'laptop'], spotify: false, laptop: true);
      await follow(['spotify', 'laptop'], spotify: false, laptop: false);
      expect(audio.rtp.state, 'playing');
      expect(requests, requestsBeforePause);
      await follow(['spotify', 'laptop'], spotify: false, laptop: true);
      expect(requests, requestsBeforePause);
    },
  );

  test('editing existing priority changes transport', () async {
    await follow(['laptop', 'spotify']);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await follow(['spotify', 'laptop']);
    expect(audio.waitingForPriority, isTrue);
    await follow(['laptop', 'spotify']);
    expect(audio.rtp.state, 'playing');
  });

  test('turning off cancels a pending priority return', () async {
    await follow(['spotify', 'laptop']);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await audio.stopRtp();
    await follow(['spotify', 'laptop'], spotify: false);
    expect(requests.where((action) => action == 'start'), hasLength(1));
    expect(audio.waitingForPriority, isFalse);
  });

  test(
    'recovery resumes at the saved volume while the switch stays on',
    () async {
      await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(audio.rtp.state, 'playing');
      remote = {
        ...remote,
        'state': 'recoveringMuted',
        'generation': 2,
        'muted': true,
        'percent': 10,
      };
      await audio.refreshRtp();
      await follow(['laptop', 'spotify']);
      expect(audio.playbackRequested, isTrue);
      expect(audio.resumePending, isTrue);
      expect(requests.where((action) => action == 'unmute'), hasLength(1));
      remote = {
        ...remote,
        'state': 'readyMuted',
        'selected_source': 'snapcast',
        'output_muted': false,
      };
      await audio.refreshRtp();
      await follow(['laptop', 'spotify']);
      expect(audio.rtp.state, 'playing');
      expect(audio.rtp.percent, 40);
      expect(audio.resumePending, isFalse);
      expect(requests.where((action) => action == 'unmute'), hasLength(2));
      expect(requests.where((action) => action == 'start'), hasLength(1));
    },
  );

  test('a failed volume confirmation during resume drops the intent', () async {
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    remote = {
      ...remote,
      'state': 'readyMuted',
      'generation': 2,
      'muted': true,
      'percent': 10,
      'selected_source': 'snapcast',
      'output_muted': false,
    };
    await audio.refreshRtp();
    confirmVolume = false;
    await expectLater(follow(['laptop', 'spotify']), throwsStateError);
    expect(audio.playbackRequested, isFalse);
    expect(audio.resumePending, isFalse);
    await follow(['laptop', 'spotify']);
    expect(requests.where((action) => action == 'unmute'), hasLength(1));
    expect(requests, isNot(contains('stop')));
  });

  test(
    'an explicit mute during recovery suppresses the automatic resume',
    () async {
      await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      remote = {
        ...remote,
        'state': 'recoveringMuted',
        'generation': 2,
        'muted': true,
        'percent': 10,
      };
      await audio.refreshRtp();
      expect(audio.resumePending, isTrue);
      await audio.muteRtp();
      expect(audio.muteFeedback, isNull);
      expect(audio.resumePending, isFalse);
      remote = {...remote, 'state': 'readyMuted'};
      await audio.refreshRtp();
      await follow(['laptop', 'spotify']);
      expect(audio.rtp.state, 'readyMuted');
      expect(requests.where((action) => action == 'unmute'), hasLength(1));
    },
  );

  test('priority return respects current group mute', () async {
    await follow(['spotify', 'laptop']);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await follow(['spotify', 'laptop'], spotify: false, muted: true);
    expect(audio.rtp.state, 'readyMuted');
    expect(audio.rtp.percent, 40);
    expect(requests, isNot(contains('unmute')));
  });

  test('removing laptop from priority never reconnects it', () async {
    await follow(['spotify'], spotify: false);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await follow(['spotify'], spotify: false);
    expect(requests, isNot(contains('unmute')));
  });
  test(
    'completed recovery between polls hands off to Spotify by priority',
    () async {
      await follow(['spotify', 'laptop'], spotify: false);
      await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(audio.rtp.state, 'playing');
      remote = {
        ...remote,
        'state': 'readyMuted',
        'generation': 2,
        'muted': true,
        'percent': 10,
        'selected_source': 'snapcast',
        'output_muted': false,
      };
      await audio.refreshRtp();
      expect(audio.resumePending, isTrue);
      await follow(['spotify', 'laptop']);
      expect(requests.last, 'standby');
      expect(audio.waitingForPriority, isTrue);
      expect(audio.resumePending, isFalse);
      expect(requests, isNot(contains('stop')));
      await follow(['spotify', 'laptop'], spotify: false);
      expect(audio.rtp.state, 'playing');
      expect(audio.rtp.percent, 40);
    },
  );

  test('a superseded resume ramp is retried on the next pass', () async {
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(audio.rtp.state, 'playing');
    remote = {
      ...remote,
      'state': 'readyMuted',
      'generation': 2,
      'muted': true,
      'percent': 10,
      'selected_source': 'snapcast',
      'output_muted': false,
    };
    await audio.refreshRtp();
    expect(audio.resumePending, isTrue);
    supersedeVolume = true;
    await follow(['laptop', 'spotify']);
    expect(audio.rtp.state, 'readyMuted');
    expect(audio.playbackRequested, isTrue);
    expect(audio.resumePending, isTrue);
    await follow(['laptop', 'spotify']);
    expect(audio.rtp.state, 'playing');
    expect(audio.rtp.percent, 40);
    expect(audio.resumePending, isFalse);
  });

  test(
    'a group muted elsewhere mutes and later resumes the receiver',
    () async {
      await follow(['laptop', 'spotify']);
      await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(audio.rtp.state, 'playing');
      await follow(['laptop', 'spotify'], muted: true);
      expect(requests, contains('mute'));
      expect(audio.rtp.state, 'readyMuted');
      expect(audio.muteFeedback, isNull);
      await follow(['laptop', 'spotify'], muted: true);
      expect(requests.where((action) => action == 'mute'), hasLength(1));
      await follow(['laptop', 'spotify']);
      expect(audio.rtp.state, 'playing');
      expect(audio.rtp.percent, 40);
      expect(requests.where((action) => action == 'unmute'), hasLength(2));
    },
  );

  test('a master volume changed elsewhere reaches the receiver', () async {
    await follow(['laptop', 'spotify']);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(audio.rtp.percent, 40);
    await follow(['laptop', 'spotify'], master: 40);
    expect(audio.rtp.percent, 20);
    expect(audio.rtp.state, 'playing');
  });

  test('a local ramp is not undone by unchanged configuration', () async {
    await follow(['laptop', 'spotify']);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await audio.setPlaybackLevels(groupVolume: 40, speakerLevel: 50);
    expect(audio.rtp.percent, 20);
    final before = requests.length;
    await follow(['laptop', 'spotify']);
    expect(requests.length, before);
    expect(audio.rtp.percent, 20);
  });

  test(
    'a failed heartbeat clears its mute doubt once the controller answers',
    () async {
      await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await audio.muteRtp();
      expect(audio.canUnmute, isTrue);
      failHeartbeat = true;
      audio.attachApp();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(audio.muteFeedback, 'Mute unconfirmed');
      expect(audio.rtpError, isNotNull);
      expect(audio.canUnmute, isFalse);
      failHeartbeat = false;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(audio.muteFeedback, isNull);
      expect(audio.rtpError, isNull);
      expect(audio.canUnmute, isTrue);
    },
  );

  test(
    'an app side error survives heartbeats until playback is enabled',
    () async {
      await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      audio.reportError('Speaker volume could not be confirmed.');
      audio.attachApp();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(requests.where((action) => action == 'app-heartbeat'), isNotEmpty);
      expect(audio.rtpError, 'Speaker volume could not be confirmed.');
      await audio.muteRtp();
      await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
      expect(audio.rtpError, isNull);
    },
  );

  test('disconnect during activity probe prevents switching', () async {
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    var connected = true;
    final activity = Completer<bool>();
    final coordinator = GroupAudioCoordinator(
      audio: audio,
      configuration: () => configuration(['spotify', 'laptop']),
      runtime: () => const SystemRuntime(
        onlineSnapClients: [],
        sources: [AudioSourceStatus(id: 'spotify', active: true)],
      ),
      online: () => connected,
      desktopActive: () => activity.future,
    );
    final refreshing = coordinator.refresh();
    connected = false;
    activity.complete(true);
    await refreshing;
    expect(audio.rtp.state, 'playing');
    expect(requests, isNot(contains('stop')));
    coordinator.dispose();
  });

  test(
    'source changes during a refresh are processed without waiting for the timer',
    () async {
      final activity = Completer<bool>();
      var probes = 0;
      final coordinator = GroupAudioCoordinator(
        audio: audio,
        configuration: () => configuration(['spotify', 'laptop']),
        runtime: () => const SystemRuntime(onlineSnapClients: [], sources: []),
        online: () => true,
        desktopActive: () {
          probes++;
          return probes == 1 ? activity.future : Future.value(true);
        },
      );
      final first = coordinator.refresh();
      final changed = coordinator.refresh();
      activity.complete(true);
      await Future.wait([first, changed]);
      expect(probes, 2);
      expect(requests, isEmpty);
      coordinator.dispose();
    },
  );

  test('failed activity probe cannot authorize an automatic start', () async {
    await follow(['spotify', 'laptop']);
    await audio.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await Future<void>.delayed(Duration.zero);
    final coordinator = GroupAudioCoordinator(
      audio: audio,
      configuration: () => configuration(['laptop', 'spotify']),
      runtime: () => const SystemRuntime(onlineSnapClients: [], sources: []),
      online: () => true,
      desktopActive: () async => throw StateError('Activity unavailable'),
    );
    await coordinator.refresh();
    expect(requests, isNot(contains('unmute')));
    coordinator.dispose();
  });
}
