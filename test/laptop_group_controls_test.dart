import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/ui/playback_groups_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'laptop_playback_test.dart' as playback;

class GroupCommands extends MqttService {
  void Function(double)? onGroupVolume;
  void Function(double)? onSpeakerLevel;
  Map<String, double>? savedSourceLevels;
  final volumes = <double>[];
  final levels = <double>[];
  final mutes = <bool>[];
  static const saved = CommandResult(
    requestId: 'request',
    success: true,
    revision: 2,
    error: null,
  );

  @override
  Future<CommandResult?> upsertGroup({
    required int expectedRevision,
    required String? groupId,
    required String name,
    required List<String> speakerIds,
    required List<String> sourcePriority,
    Map<String, double>? sourceLevels,
    required String volumeMode,
    required double masterVolume,
    required bool muted,
  }) async {
    savedSourceLevels = sourceLevels;
    volumes.add(masterVolume);
    mutes.add(muted);
    onGroupVolume?.call(masterVolume);
    return CommandResult(
      requestId: 'request',
      success: true,
      revision: expectedRevision + 1,
      error: null,
    );
  }

  @override
  Future<CommandResult?> setSpeakerLevel({
    required int expectedRevision,
    required String speakerId,
    required double level,
  }) async {
    levels.add(level);
    onSpeakerLevel?.call(level);
    return CommandResult(
      requestId: 'request',
      success: true,
      revision: expectedRevision + 1,
      error: null,
    );
  }
}

class DelayedGroupCommands extends GroupCommands {
  final requests =
      <
        ({
          String kind,
          int revision,
          double value,
          Completer<CommandResult?> completion,
        })
      >[];

  Future<CommandResult?> hold(String kind, int revision, double value) {
    final completion = Completer<CommandResult?>();
    requests.add((
      kind: kind,
      revision: revision,
      value: value,
      completion: completion,
    ));
    return completion.future;
  }

  @override
  Future<CommandResult?> upsertGroup({
    required int expectedRevision,
    required String? groupId,
    required String name,
    required List<String> speakerIds,
    required List<String> sourcePriority,
    Map<String, double>? sourceLevels,
    required String volumeMode,
    required double masterVolume,
    required bool muted,
  }) => hold('group', expectedRevision, masterVolume);

  @override
  Future<CommandResult?> setSpeakerLevel({
    required int expectedRevision,
    required String speakerId,
    required double level,
  }) => hold('speaker', expectedRevision, level);
}

SystemConfiguration configuration(
  double master,
  double level, {
  int revision = 1,
}) => SystemConfiguration(
  stateId: 'state',
  revision: revision,
  speakers: [
    ConfiguredSpeaker(
      id: 'configured',
      name: 'XPS',
      snapClientId: 'speaker',
      sensorId: null,
      fullVolumeDistance: 1000,
      muteDistance: 5000,
      level: level,
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
      masterVolume: master,
      muted: false,
    ),
  ],
  sources: const [AudioSource(id: 'laptop', name: 'Laptop')],
);

void main() {
  testWidgets('a newer slider value stops an outdated local volume ramp', (
    tester,
  ) async {
    final commands = DelayedGroupCommands();
    final firstGain = Completer<ProcessResult>();
    final levels = <int>[];
    final service = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        levels.add(request['percent'] as int);
        if (levels.length == 1) return firstGain.future;
        return playback.response(
          playback.status('playing', percent: levels.last),
        );
      },
    );
    service.rtp = RtpStatus(playback.status('playing', percent: 10));
    final container = ProviderContainer(
      overrides: [
        mqttServiceProvider.overrideWithValue(commands),
        localAudioServiceProvider.overrideWith((ref) => service),
        systemConfigurationProvider.overrideWith(
          (ref) => configuration(10, 100),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
      ),
    );
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    slider.onChangeStart!(10);
    slider.onChanged!(80);
    await tester.pump();
    expect(levels, [20]);
    slider.onChanged!(20);
    slider.onChangeEnd!(20);
    firstGain.complete(
      playback.response(playback.status('playing', percent: 20)),
    );
    await tester.pumpAndSettle();
    expect(levels, [
      20,
    ], reason: 'The old 80 percent ramp must stop after its in flight step');
    expect(commands.requests.single.value, 20);
    commands.requests.single.completion.complete(
      const CommandResult(
        requestId: 'saved',
        success: true,
        revision: 2,
        error: null,
      ),
    );
    container.read(systemConfigurationProvider.notifier).state = configuration(
      20,
      100,
      revision: 2,
    );
    await tester.pump();
    expect(service.rtp.percent, 20);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'volume sends while dragging and does not save twice on release',
    (tester) async {
      final commands = DelayedGroupCommands();
      final container = ProviderContainer(
        overrides: [
          mqttServiceProvider.overrideWithValue(commands),
          localAudioServiceProvider.overrideWith(
            (ref) => LocalAudioService(available: false),
          ),
          systemConfigurationProvider.overrideWith(
            (ref) => configuration(80, 50),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
        ),
      );
      final slider = tester.widget<Slider>(find.byType(Slider).first);
      slider.onChangeStart!(80);
      slider.onChanged!(60);
      await tester.pump();
      expect(
        commands.requests,
        hasLength(1),
        reason: 'Playback should react before the pointer is released',
      );
      slider.onChanged!(30);
      await tester.pump();
      commands.requests.first.completion.complete(
        const CommandResult(
          requestId: 'first',
          success: true,
          revision: 2,
          error: null,
        ),
      );
      container.read(systemConfigurationProvider.notifier).state =
          configuration(60, 50, revision: 2);
      await tester.pump();
      expect(commands.requests, hasLength(2));
      expect(commands.requests.last.value, 30);
      expect(tester.widget<Slider>(find.byType(Slider).first).value, 30);
      slider.onChangeEnd!(30);
      commands.requests.last.completion.complete(
        const CommandResult(
          requestId: 'last',
          success: true,
          revision: 3,
          error: null,
        ),
      );
      container.read(systemConfigurationProvider.notifier).state =
          configuration(30, 50, revision: 3);
      await tester.pump();
      expect(commands.requests, hasLength(2));
      expect(
        find.text('Volume saved'),
        findsNothing,
        reason: 'Routine slider changes do not need repeated snackbars',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final snapshotFirst in [false, true]) {
    testWidgets(
      'rapid slider edits preserve the latest value, snapshot first $snapshotFirst',
      (tester) async {
        final commands = DelayedGroupCommands();
        final container = ProviderContainer(
          overrides: [
            mqttServiceProvider.overrideWithValue(commands),
            localAudioServiceProvider.overrideWith(
              (ref) => LocalAudioService(available: false),
            ),
            systemConfigurationProvider.overrideWith(
              (ref) => configuration(80, 50),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(body: PlaybackGroupsPage()),
            ),
          ),
        );
        void edit(int index, double value) {
          final slider = tester.widget<Slider>(find.byType(Slider).at(index));
          slider.onChangeStart!(slider.value);
          slider.onChanged!(value);
          slider.onChangeEnd!(value);
        }

        void publish(int revision, double master, double level) {
          final updated = configuration(master, level);
          container
              .read(systemConfigurationProvider.notifier)
              .state = SystemConfiguration(
            stateId: updated.stateId,
            revision: revision,
            speakers: updated.speakers,
            groups: updated.groups,
            sources: updated.sources,
          );
        }

        Future<void> accept(int index, double master, double level) async {
          final request = commands.requests[index];
          final result = CommandResult(
            requestId: 'request-$index',
            success: true,
            revision: request.revision + 1,
            error: null,
          );
          if (snapshotFirst) {
            publish(result.revision, master, level);
            await tester.pump();
            expect(commands.requests, hasLength(index + 1));
            request.completion.complete(result);
          } else {
            request.completion.complete(result);
            await tester.pump();
            expect(commands.requests, hasLength(index + 1));
            publish(result.revision, master, level);
          }
          await tester.pump();
        }

        edit(0, 60);
        await tester.pump();
        edit(0, 45);
        edit(0, 20);
        edit(1, 25);
        await tester.pump();
        expect(
          commands.requests,
          hasLength(1),
          reason: 'Only one configuration save can use the current revision',
        );
        expect(tester.widget<Slider>(find.byType(Slider).first).value, 20);
        expect(tester.widget<Slider>(find.byType(Slider).last).value, 25);

        await accept(0, 60, 50);
        expect(commands.requests, hasLength(2));
        expect(
          commands.requests[1].value,
          20,
          reason: 'The intermediate 45 percent edit is superseded',
        );
        expect(commands.requests[1].revision, 2);
        expect(tester.widget<Slider>(find.byType(Slider).first).value, 20);
        expect(tester.widget<Slider>(find.byType(Slider).last).value, 25);
        await accept(1, 20, 50);
        expect(commands.requests, hasLength(3));
        expect(commands.requests[2].kind, 'speaker');
        expect(commands.requests[2].revision, 3);
        await accept(2, 20, 25);
        expect(tester.widget<Slider>(find.byType(Slider).first).value, 20);
        expect(tester.widget<Slider>(find.byType(Slider).last).value, 25);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('group editor saves source balance without changing master', (
    tester,
  ) async {
    final commands = GroupCommands();
    final service = LocalAudioService(available: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mqttServiceProvider.overrideWith((ref) => commands),
          localAudioServiceProvider.overrideWith((ref) => service),
          systemConfigurationProvider.overrideWith(
            (ref) => configuration(60, 80),
          ),
          serverOnlineProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit).first);
    await tester.pumpAndSettle();
    tester
        .widget<Slider>(find.byKey(const ValueKey('source-level-laptop')))
        .onChanged!(75);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(commands.savedSourceLevels, {'laptop': 75});
    expect(commands.volumes, [60]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Spotify standby does not appear as a muted group', (
    tester,
  ) async {
    final service = LocalAudioService(
      available: true,
      runner: (_, _) async =>
          ProcessResult(1, 0, jsonEncode(playback.status('idle')), ''),
    );
    service.rtp = RtpStatus({
      ...playback.status('readyMuted'),
      'selected_source': 'snapcast',
      'output_muted': false,
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localAudioServiceProvider.overrideWith((ref) => service),
          systemConfigurationProvider.overrideWith(
            (ref) => configuration(80, 50),
          ),
          serverOnlineProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.volume_off), findsNothing);
    await tester.tap(find.byIcon(Icons.edit).first);
    await tester.pumpAndSettle();
    final mute = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Mute group'),
    );
    expect(mute.value, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a receiver muted for recovery does not seed the group mute', (
    tester,
  ) async {
    final commands = GroupCommands();
    final requests = <String>[];
    final service = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        return ProcessResult(
          1,
          0,
          jsonEncode(playback.status('recoveringMuted', generation: 2)),
          '',
        );
      },
    );
    service.rtp = RtpStatus(playback.status('recoveringMuted', generation: 2));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mqttServiceProvider.overrideWith((ref) => commands),
          localAudioServiceProvider.overrideWith((ref) => service),
          systemConfigurationProvider.overrideWith(
            (ref) => configuration(80, 50),
          ),
          serverOnlineProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit).first);
    await tester.pumpAndSettle();
    final mute = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Mute group'),
    );
    expect(mute.value, isFalse);
    await tester.enterText(find.byType(TextField), 'Office');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(commands.mutes, [false]);
    expect(requests, isNot(contains('mute')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a handoff while the editor is open does not discard the edit', (
    tester,
  ) async {
    final commands = GroupCommands();
    final requests = <String>[];
    var remote = <String, dynamic>{
      ...playback.status('playing', percent: 40),
      'selected_source': 'rtp',
    };
    final service = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        return ProcessResult(1, 0, jsonEncode(remote), '');
      },
    );
    service.rtp = RtpStatus(remote);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mqttServiceProvider.overrideWith((ref) => commands),
          localAudioServiceProvider.overrideWith((ref) => service),
          systemConfigurationProvider.overrideWith(
            (ref) => configuration(80, 50),
          ),
          serverOnlineProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit).first);
    await tester.pumpAndSettle();
    // Group priority hands the receiver to Snapcast while the dialog is open, moving its generation on.
    remote = {
      ...playback.status('readyMuted', generation: 2, percent: 40),
      'selected_source': 'snapcast',
      'output_muted': false,
    };
    await service.refreshRtp();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Office');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('connection changed'), findsNothing);
    expect(commands.volumes, [80]);
    expect(commands.mutes, [false]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saving an unmuted group resumes a paused laptop session', (
    tester,
  ) async {
    final commands = GroupCommands();
    final requests = <String>[];
    var remote = <String, dynamic>{
      ...playback.status('readyMuted'),
      'selected_source': 'snapcast',
      'output_muted': false,
    };
    final service = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        if (request['action'] == 'volume') {
          remote = {...remote, 'percent': request['percent']};
        }
        if (request['action'] == 'unmute') {
          remote = {
            ...playback.status('playing', percent: remote['percent'] as int),
            'selected_source': 'rtp',
          };
        }
        return ProcessResult(1, 0, jsonEncode(remote), '');
      },
    );
    service.rtp = RtpStatus(remote);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mqttServiceProvider.overrideWith((ref) => commands),
          localAudioServiceProvider.overrideWith((ref) => service),
          systemConfigurationProvider.overrideWith(
            (ref) => configuration(80, 50),
          ),
          serverOnlineProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit).first);
    await tester.pumpAndSettle();
    final mute = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Mute group'),
    );
    expect(mute.value, isFalse);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(requests.where((action) => action == 'volume'), hasLength(3));
    expect(requests.where((action) => action == 'unmute'), hasLength(1));
    expect(service.rtp.state, 'playing');
    expect(service.rtp.percent, 40);
    expect(service.playbackRequested, isTrue);
    expect(commands.volumes, [80]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an unchanged save during a Spotify handoff sends nothing', (
    tester,
  ) async {
    final commands = GroupCommands();
    final requests = <String>[];
    var remote = <String, dynamic>{
      ...playback.status('playing', percent: 40),
      'selected_source': 'rtp',
    };
    final service = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        if (request['action'] == 'standby') {
          remote = {
            ...playback.status('readyMuted', generation: 2, percent: 40),
            'selected_source': 'snapcast',
            'output_muted': false,
          };
        }
        return ProcessResult(1, 0, jsonEncode(remote), '');
      },
    );
    service.rtp = RtpStatus(remote);
    await service.enablePlayback(groupVolume: 80, speakerLevel: 50);
    await service.followGroupPriority(
      configuration: configuration(80, 50),
      runtime: const SystemRuntime(
        onlineSnapClients: [],
        sources: [AudioSourceStatus(id: 'spotify', active: true)],
      ),
      desktopActive: true,
    );
    expect(service.waitingForPriority, isFalse);
    // The group lists only laptop audio, so Spotify wins nothing until the priority says so.
    await service.followGroupPriority(
      configuration: SystemConfiguration(
        stateId: 'state',
        revision: 1,
        speakers: configuration(80, 50).speakers,
        groups: const [
          PlaybackGroup(
            id: 'group',
            name: 'Default',
            speakerIds: ['configured'],
            sourcePriority: ['spotify', 'laptop'],
            volumeMode: 'manual',
            masterVolume: 80,
            muted: false,
          ),
        ],
        sources: const [AudioSource(id: 'laptop', name: 'Laptop')],
      ),
      runtime: const SystemRuntime(
        onlineSnapClients: [],
        sources: [AudioSourceStatus(id: 'spotify', active: true)],
      ),
      desktopActive: true,
    );
    expect(service.waitingForPriority, isTrue);
    final before = requests.length;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mqttServiceProvider.overrideWith((ref) => commands),
          localAudioServiceProvider.overrideWith((ref) => service),
          systemConfigurationProvider.overrideWith(
            (ref) => configuration(80, 50),
          ),
          serverOnlineProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.volume_off), findsNothing);
    await tester.tap(find.byIcon(Icons.edit).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(requests.length, before);
    expect(service.waitingForPriority, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'group and speaker levels stay independent during laptop playback',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final commands = GroupCommands();
      final requests = <String>[];
      var remote = playback.status('playing', percent: 40);
      final service = LocalAudioService(
        available: true,
        runner: (executable, arguments) async {
          final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
          requests.add(request['action'] as String);
          if (request['action'] == 'volume') {
            remote = playback.status(
              'playing',
              percent: request['percent'] as int,
            );
          }
          if (request['action'] == 'mute') {
            remote = playback.status(
              'readyMuted',
              generation: 2,
              percent: remote['percent'] as int,
            );
          }
          return ProcessResult(1, 0, jsonEncode(remote), '');
        },
      );
      service.rtp = RtpStatus(remote);
      final container = ProviderContainer(
        overrides: [
          localAudioServiceProvider.overrideWith((ref) => service),
          mqttServiceProvider.overrideWithValue(commands),
          systemConfigurationProvider.overrideWith(
            (ref) => configuration(80, 50),
          ),
        ],
      );
      addTearDown(container.dispose);
      commands.onGroupVolume = (master) {
        final current = container.read(systemConfigurationProvider)!;
        container
            .read(systemConfigurationProvider.notifier)
            .state = configuration(
          master,
          current.speakers.single.level,
          revision: current.revision + 1,
        );
      };
      commands.onSpeakerLevel = (level) {
        final current = container.read(systemConfigurationProvider)!;
        container
            .read(systemConfigurationProvider.notifier)
            .state = configuration(
          current.groups.single.masterVolume,
          level,
          revision: current.revision + 1,
        );
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: PlaybackGroupsPage())),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(find.byType(Slider).first).value, 80);
      expect(tester.widget<Slider>(find.byType(Slider).last).value, 50);

      tester.widget<Slider>(find.byType(Slider).first).onChangeEnd!(60);
      await tester.pumpAndSettle();
      expect(service.rtp.percent, 30);
      expect(tester.widget<Slider>(find.byType(Slider).first).value, 60);
      expect(tester.widget<Slider>(find.byType(Slider).last).value, 50);
      expect(commands.levels, isEmpty);

      tester.widget<Slider>(find.byType(Slider).last).onChangeEnd!(25);
      await tester.pumpAndSettle();
      expect(service.rtp.percent, 15);
      expect(tester.widget<Slider>(find.byType(Slider).first).value, 60);
      expect(tester.widget<Slider>(find.byType(Slider).last).value, 25);
      expect(commands.volumes, [60]);
      expect(commands.levels, [25]);

      tester.widget<Slider>(find.byType(Slider).last).onChangeEnd!(0);
      await tester.pumpAndSettle();
      tester.widget<Slider>(find.byType(Slider).first).onChangeEnd!(40);
      await tester.pumpAndSettle();
      expect(service.rtp.percent, 0);
      expect(tester.widget<Slider>(find.byType(Slider).last).value, 0);
      tester.widget<Slider>(find.byType(Slider).last).onChangeEnd!(50);
      await tester.pumpAndSettle();
      expect(service.rtp.percent, 20);
      expect(tester.widget<Slider>(find.byType(Slider).first).value, 40);

      await tester.tap(find.byIcon(Icons.edit).first);
      await tester.pumpAndSettle();
      expect(find.text('Master volume 40%'), findsNWidgets(2));
      final previousRequests = requests.length;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(requests.length, previousRequests);

      await tester.tap(find.byIcon(Icons.edit).first);
      await tester.pumpAndSettle();
      tester
          .widget<Slider>(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(Slider),
                )
                .last,
          )
          .onChanged!(30);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(service.rtp.percent, 15);
      expect(tester.widget<Slider>(find.byType(Slider).first).value, 30);
      expect(tester.widget<Slider>(find.byType(Slider).last).value, 50);

      await tester.tap(find.byIcon(Icons.edit).first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Mute group'));
      await tester.tap(find.text('Mute group'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(requests, contains('mute'));
      expect(service.rtp.muted, isTrue);
      remote = playback.status('idle');
      await service.refreshRtp();
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(find.byType(Slider).first).value, 30);
      expect(tester.widget<Slider>(find.byType(Slider).last).value, 50);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
