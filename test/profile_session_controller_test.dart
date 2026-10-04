import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:final_project/ui/profile/me_tab.dart';
import 'package:final_project/ui/profile/profile_shell.dart';
import 'package:final_project/ui/profile/syren_widgets.dart';
import 'package:final_project/ui/syren_theme.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:final_project/models/server_status.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/profile_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mqtt_client/mqtt_client.dart';

void main() {
  late Directory directory;
  late Box<String> storage;
  late ProfileMqtt mqtt;
  late ProfileSessionController controller;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('syren_profiles_');
    Hive.init(directory.path);
    storage = await Hive.openBox<String>('profiles', bytes: Uint8List(0));
    mqtt = ProfileMqtt();
    controller = ProfileSessionController(mqtt, storage);
    controller.receive('Configuration', mqtt.configuration);
  });
  tearDown(() async {
    await controller.stopPc();
    controller.dispose();
    await Hive.close();
    directory.deleteSync(recursive: true);
  });

  test('ending a PC destination releases its app capture ownership', () {
    controller.pcSessionId = 'pc';
    controller.pcOwner = 'first';
    controller.receive('Catalogue', {
      'generation': 2,
      'revision': 10,
      'sessions': [
        {'id': 'pc', 'state': 'ended'},
      ],
    });
    expect(controller.pcSessionId, isNull);
    expect(controller.pcOwner, isNull);
  });

  test('PC output choices are remembered and default to automatic', () async {
    expect(controller.preferredPcMode, 'auto');
    await controller.setPcMode('stable');
    await controller.rememberPcSpeaker('xps');
    final reopened = ProfileSessionController(ProfileMqtt(), storage);
    expect(reopened.preferredPcMode, 'stable');
    expect(reopened.preferredPcSpeaker, 'xps');
    reopened.dispose();
    await controller.setPcMode('fast');
    expect(controller.preferredPcMode, 'fast');
    await controller.rememberPcSpeaker(null);
    expect(controller.preferredPcSpeaker, isNull);
    await storage.put('pcMode', 'invalid');
    expect(controller.preferredPcMode, 'auto');
  });

  test('desktop output changes update the remembered mode while playing', () {
    controller.pcSessionId = 'pc';
    controller.receivePcCaptureStatus({
      'mode': 'stable',
      'activeModes': ['stable'],
      'realtimePriority': 86,
    });
    expect(controller.preferredPcMode, 'stable');
    expect(controller.pcTransportDescription('stable'), 'Snapcast only');
    controller.pcSessionId = null;
    controller.receivePcCaptureStatus({'mode': 'fast'});
    expect(controller.preferredPcMode, 'stable');
  });

  test('Fast requires a speaker before creating the session', () async {
    controller.selectedId = 'first';
    await controller.setPcMode('fast');
    await expectLater(controller.startPc('house'), throwsStateError);
    expect(
      mqtt.commands.where((command) => command['action'] == 'pc'),
      isEmpty,
    );
  });

  test('volume edits keep only the newest pending value', () async {
    mqtt.configuration['groups'] = [
      {'id': 'room', 'sourceLevels': <String, dynamic>{}, 'masterVolume': 50},
    ];
    mqtt.heldVolume = Completer<void>();
    final first = controller.setVolume('room', 10);
    final second = controller.setVolume('room', 20);
    final third = controller.setVolume('room', 30);
    expect(
      mqtt.commands.where((command) => command['action'] == 'group').length,
      1,
    );
    mqtt.heldVolume!.complete();
    await Future.wait([first, second, third]);
    expect(
      mqtt.commands
          .where((command) => command['action'] == 'group')
          .map((command) => command['masterVolume']),
      [10, 30],
    );
  });

  Widget shell() => MaterialApp(
    theme: syrenTheme(),
    home: ProfileShell(
      controller: controller,
      positioning: PositioningControls(
        isMeasuring: () => false,
        toggle: () async {},
      ),
    ),
  );

  testWidgets('empty source levels use defaults on the profile page', (
    tester,
  ) async {
    mqtt.configuration['speakers'] = <Object>[];
    mqtt.configuration['sourcePolicies'] = {'spotify': 'playing'};
    mqtt.configuration['groups'] = [
      {
        'id': 'room',
        'name': 'Room',
        'speakerIds': <Object>[],
        'enabledSources': ['spotify', 'laptop'],
        'sourceLevels': <String, dynamic>{},
        'masterVolume': 50,
        'muted': false,
      },
    ];
    controller.selectedId = 'first';
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Room'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('100%'), findsNWidgets(2));
  });

  test(
    'remembering a profile does not reclaim positioning from another app',
    () async {
      await controller.select('first');
      controller.dispose();
      controller = ProfileSessionController(mqtt, storage);
      controller.receive('Configuration', mqtt.configuration);
      expect(controller.selectedId, 'first');
      expect(controller.lease, isNull);
      expect(controller.reportDistance('sensor-a', 1000), isFalse);
    },
  );

  test(
    'profile switching clears position authority and preserves the PC owner',
    () async {
      await controller.select('first');
      controller.pcSessionId = 'pc';
      controller.pcOwner = 'first';
      await controller.select('second');
      expect(controller.selectedId, 'second');
      expect(controller.pcOwner, 'first');
      expect(controller.pcSessionId, 'pc');
      expect(
        mqtt.commands.where((command) => command['action'] == 'pc'),
        isEmpty,
      );
    },
  );

  test('a new distance never refreshes a different sensor reading', () async {
    await controller.select('first');
    expect(controller.reportDistance('sensor-a', 1100), isTrue);
    expect(controller.reportDistance('sensor-b', 1200), isTrue);
    expect(mqtt.published.last.$2['distances'], {'sensor-b': 1200.0});
    expect(mqtt.published.last.$2['profileId'], 'first');
    expect(mqtt.published.last.$2['instanceId'], mqtt.clientId);
    expect(mqtt.published.last.$2['lease'], 'lease-first');
  });

  test(
    'stale catalogue and receiver revisions cannot replace reported state',
    () {
      controller.receive('Receivers', {
        'generation': 2,
        'revision': 4,
        'receivers': ['new'],
      });
      controller.receive('Receivers', {
        'generation': 1,
        'revision': 99,
        'receivers': ['old'],
      });
      controller.receive('Receivers', {
        'generation': 2,
        'revision': 3,
        'receivers': ['duplicate'],
      });
      expect(controller.receivers!['receivers'], ['new']);
    },
  );

  test('an online version two server ends profile playback', () {
    final service = MqttService();
    final profiles = ProfileSessionController(service, storage);
    addTearDown(profiles.dispose);
    var legacyConfigurations = 0;
    service.onConfiguration = (_) => legacyConfigurations++;
    service.handleMessage(
      'SyrenSystem/v3/Configuration',
      jsonEncode(mqtt.configuration),
    );
    final status = {
      'sessionId': 'server',
      'stateId': 'house',
      'online': true,
      'connectedSpeakerIds': <Object>[],
    };
    service.handleMessage(
      'SyrenSystem/SyrenServer/Status',
      jsonEncode({...status, 'protocolVersion': 3}),
    );
    service.handleMessage(
      'SyrenSystem/SyrenServer/Configuration',
      jsonEncode(legacyConfiguration),
    );
    expect(service.profileMode, isTrue);
    expect(profiles.configuration, isNotNull);
    expect(legacyConfigurations, 0);
    service.handleMessage('SyrenSystem/SyrenServer/Status', jsonEncode(status));
    expect(service.profileMode, isFalse);
    expect(profiles.configuration, isNull);
    expect(legacyConfigurations, 1);
  });

  test('an offline server fails profile commands and is replayed', () async {
    final service = ConnectedMqtt();
    final profiles = ProfileSessionController(service, storage);
    addTearDown(profiles.dispose);
    ServerStatus? legacyStatus;
    service.onServerStatus = (status) => legacyStatus = status;
    service.handleMessage(
      'SyrenSystem/v3/Configuration',
      jsonEncode(mqtt.configuration),
    );
    final pending = service.profileCommand({'action': 'policy'});
    service.handleMessage(
      'SyrenSystem/SyrenServer/Status',
      jsonEncode({
        'sessionId': 'server',
        'stateId': 'house',
        'online': false,
        'protocolVersion': 3,
      }),
    );
    await expectLater(pending, throwsStateError);
    expect(service.profileMode, isTrue);
    expect(profiles.serverOnline, isFalse);
    await expectLater(profiles.command('policy', {}), throwsStateError);
    expect(legacyStatus, isNull);
    service.handleMessage('SyrenSystem/v3/Configuration', '');
    expect(legacyStatus?.online, isFalse);
  });

  testWidgets('the Spotify policy always shows the server value', (
    tester,
  ) async {
    mqtt.configuration['speakers'] = <Object>[];
    mqtt.configuration['sourcePolicies'] = {'spotify': 'playing'};
    controller.selectedId = 'first';
    await tester.pumpWidget(shell());
    await tester.tap(find.text('Rules'));
    await tester.pumpAndSettle();
    final policy = find.byType(SegmentedChoice<String>);
    await tester.scrollUntilVisible(
      policy,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    String shown() => tester.widget<SegmentedChoice<String>>(policy).value;
    expect(shown(), 'playing');

    mqtt.failures['policy'] = 1;
    await tester.ensureVisible(find.text('Waits its turn'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Waits its turn'));
    await tester.pumpAndSettle();
    expect(shown(), 'playing');
    expect(
      mqtt.commands.where((command) => command['action'] == 'policy'),
      hasLength(1),
    );

    controller.receive('Configuration', {
      ...mqtt.configuration,
      'revision': 2,
      'sourcePolicies': {'spotify': 'connected'},
    });
    await tester.pumpAndSettle();
    expect(shown(), 'connected');
  });

  test('a cleared retained configuration ends profile playback', () {
    final service = MqttService();
    final profiles = ProfileSessionController(service, storage);
    addTearDown(profiles.dispose);
    service.handleMessage(
      'SyrenSystem/v3/Configuration',
      jsonEncode(mqtt.configuration),
    );
    service.handleMessage('SyrenSystem/v3/Configuration', '');
    expect(service.profileMode, isFalse);
    expect(profiles.configuration, isNull);
  });

  testWidgets('a failed controller announcement is retried', (tester) async {
    controller.dispose();
    mqtt.failures['controllerReady'] = 1;
    mqtt.commands.clear();
    controller = ProfileSessionController(mqtt, storage);
    controller.receive('Configuration', mqtt.configuration);
    await tester.pump();
    expect(controller.error, isNotNull);
    await tester.pump(const Duration(seconds: 3));
    expect(
      mqtt.commands.where((command) => command['action'] == 'controllerReady'),
      hasLength(2),
    );
    expect(controller.error, isNull);
    controller.receive('Configuration', {...mqtt.configuration, 'revision': 2});
    await tester.pump(const Duration(seconds: 3));
    expect(
      mqtt.commands.where((command) => command['action'] == 'controllerReady'),
      hasLength(2),
    );
  });

  test('a low latency speaker needs an IPv4 address or a name', () async {
    expect(
      await ProfileSessionController.speakerAddress('192.168.2.61'),
      '192.168.2.61',
    );
    expect(
      await ProfileSessionController.speakerAddress('localhost'),
      '127.0.0.1',
    );
    for (final invalid in ['', '::1']) {
      await expectLater(
        ProfileSessionController.speakerAddress(invalid),
        throwsA(isA<StateError>()),
      );
    }
  });

  test('a low latency speaker address comes from this computer', () async {
    controller.receive('Configuration', {
      ...mqtt.configuration,
      'revision': 2,
      'speakers': [
        {'id': 'xps', 'name': 'XPS', 'snapClientId': 'syren-player-1'},
        {'id': 'kitchen', 'name': 'Kitchen', 'snapClientId': 'syren-player-2'},
      ],
    });
    controller.readPairing = () async => {
      'snapclient_id': 'syren-player-1',
      'address': '192.168.2.27',
      'host': 'hifiberry.local',
    };
    expect(await controller.knownSpeakerAddress('xps'), '192.168.2.27');
    expect(await controller.knownSpeakerAddress('kitchen'), isNull);

    await storage.put('speakerAddress:kitchen', '192.168.2.61');
    expect(await controller.knownSpeakerAddress('kitchen'), '192.168.2.61');

    controller.readPairing = () async =>
        throw const ProcessException('syren-audio-control', []);
    expect(await controller.knownSpeakerAddress('xps'), isNull);
  });

  testWidgets('choosing a paired speaker fills in its address', (tester) async {
    controller.receive('Configuration', {
      ...mqtt.configuration,
      'revision': 2,
      'speakers': [
        {'id': 'xps', 'name': 'XPS', 'snapClientId': 'syren-player-1'},
      ],
    });
    controller.selectedId = 'first';
    controller.readPairing = () async => {
      'snapclient_id': 'syren-player-1',
      'address': '192.168.2.27',
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: syrenTheme(),
        home: Scaffold(
          body: PcAudioCard(
            profile: ProfileContext(
              controller: controller,
              positioning: PositioningControls(
                isMeasuring: () => false,
                toggle: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('XPS').last);
    await tester.pumpAndSettle();
    expect(find.text('Sends to 192.168.2.27'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '192.168.2.27',
    );
  });

  test('a missing speaker address fails before the PC command', () async {
    await controller.select('first');
    await expectLater(
      controller.startPc('house', speakerId: 'speaker-a', receiverAddress: ''),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('IPv4 address'),
        ),
      ),
    );
    expect(
      mqtt.commands.where((command) => command['action'] == 'pc'),
      isEmpty,
    );
    expect(controller.pcSessionId, isNull);
  });

  test('PC heartbeats repeat the latest lifecycle sequence', () {
    controller.pcSessionId = 'pc';
    controller.receive('Configuration', {
      ...mqtt.configuration,
      'generation': 3,
    });
    controller.sendPcHeartbeat();
    controller.sendPcHeartbeat();
    final events = mqtt.published
        .where((message) => message.$1 == 'SyrenSystem/v3/Lifecycle')
        .map((message) => (message.$2['action'], message.$2['eventSequence']))
        .toList();
    expect(events, [('reconcile', 2), ('heartbeat', 2), ('heartbeat', 2)]);
  });

  test('receiving version three switches MQTT distance handling', () {
    final service = MqttService();
    var forwarded = false;
    service.onProfileDistance = (identity, distance) {
      forwarded = identity == 'sensor-a';
      return true;
    };
    service.handleMessage(
      'SyrenSystem/v3/Configuration',
      jsonEncode(mqtt.configuration),
    );
    expect(service.profileMode, isTrue);
    expect(service.sendDistance('sensor-a', 1000), isTrue);
    expect(forwarded, isTrue);
  });
}

class ProfileMqtt extends MqttService {
  final configuration = <String, dynamic>{
    'protocolVersion': 3,
    'stateId': 'house',
    'generation': 2,
    'revision': 1,
    'profiles': [
      {
        'id': 'first',
        'name': 'First',
        'followMe': false,
        'sourcePriority': ['spotify', 'laptop', 'casting'],
        'overlap': <Object>[],
      },
      {
        'id': 'second',
        'name': 'Second',
        'followMe': false,
        'sourcePriority': ['spotify', 'laptop', 'casting'],
        'overlap': <Object>[],
      },
    ],
    'speakers': [
      {'id': 'speaker-a', 'sensorId': 'sensor-a'},
      {'id': 'speaker-b', 'sensorId': 'sensor-b'},
    ],
    'groups': <Object>[],
  };
  Completer<void>? heldVolume;
  final commands = <Map<String, dynamic>>[];
  final published = <(String, Map<String, dynamic>)>[];
  final failures = <String, int>{};

  @override
  Future<Map<String, dynamic>> profileCommand(
    Map<String, dynamic> fields,
  ) async {
    commands.add(fields);
    final remaining = failures[fields['action']] ?? 0;
    if (remaining > 0) {
      failures[fields['action']] = remaining - 1;
      throw StateError('Stale configuration or incompatible controller');
    }
    if (fields['action'] == 'group' && heldVolume != null) {
      await heldVolume!.future;
    }
    return {
      'requestId': 'fixture',
      'success': true,
      'revision': 1,
      'lease': 'lease-${fields['profileId']}',
    };
  }

  @override
  bool publish(
    String topic,
    Object message, {
    MqttQos qos = MqttQos.atLeastOnce,
  }) {
    published.add((topic, message as Map<String, dynamic>));
    return true;
  }
}

class ConnectedMqtt extends MqttService {
  @override
  bool publish(
    String topic,
    Object message, {
    MqttQos qos = MqttQos.atLeastOnce,
  }) => true;
}

final legacyConfiguration = <String, dynamic>{
  'stateId': 'house',
  'revision': 1,
  'speakers': <Object>[],
  'groups': <Object>[],
  'sources': <Object>[],
};
