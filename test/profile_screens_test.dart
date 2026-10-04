import 'dart:io';
import 'dart:typed_data';

import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/profile_session_controller.dart';
import 'package:final_project/ui/profile/profile_shell.dart';
import 'package:final_project/ui/syren_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mqtt_client/mqtt_client.dart';

class FakeMqtt extends MqttService {
  final commands = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> profileCommand(
    Map<String, dynamic> fields,
  ) async {
    commands.add(fields);
    return {'requestId': 'fixture', 'success': true, 'revision': 1};
  }

  @override
  bool publish(
    String topic,
    Object message, {
    MqttQos qos = MqttQos.atLeastOnce,
  }) => true;
}

Map<String, dynamic> configuration() => {
  'protocolVersion': 3,
  'stateId': 'house',
  'generation': 2,
  'revision': 1,
  'playbackActivated': true,
  'profiles': [
    {
      'id': 'maya',
      'name': 'Maya',
      'followMe': false,
      'sourcePriority': ['spotify', 'laptop', 'casting'],
      'overlap': <Object>[],
    },
    {
      'id': 'jonas',
      'name': 'Jonas',
      'followMe': false,
      'sourcePriority': ['spotify', 'laptop', 'casting'],
      'overlap': <Object>[],
    },
  ],
  'sourcePolicies': {'spotify': 'playing'},
  'speakers': [
    {
      'id': 'office',
      'name': 'Office speaker',
      'snapClientId': 'player-1',
      'sensorId': null,
      'fullVolumeDistance': 1000,
      'muteDistance': 5000,
      'level': 40,
    },
    {
      'id': 'kitchen',
      'name': 'Kitchen speaker',
      'snapClientId': 'player-2',
      'sensorId': null,
      'fullVolumeDistance': 1000,
      'muteDistance': 5000,
      'level': 30,
    },
  ],
  'groups': [
    {
      'id': 'office-room',
      'name': 'Office',
      'speakerIds': ['office'],
      'enabledSources': ['laptop', 'spotify'],
      'sourceLevels': {'spotify': 100, 'laptop': 100},
      'masterVolume': 60,
      'muted': false,
    },
    {
      'id': 'kitchen-room',
      'name': 'Kitchen',
      'speakerIds': ['kitchen'],
      'enabledSources': ['spotify'],
      'sourceLevels': <String, dynamic>{},
      'masterVolume': 48,
      'muted': false,
    },
  ],
};

void main() {
  late Directory directory;
  late FakeMqtt mqtt;
  late ProfileSessionController controller;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('syren_screens_');
    Hive.init(directory.path);
    mqtt = FakeMqtt();
    controller = ProfileSessionController(
      mqtt,
      // In memory, so writes started inside widget tests never wait on disk.
      await Hive.openBox<String>('profiles', bytes: Uint8List(0)),
    );
    controller.receive('Configuration', configuration());
    controller.receive('Catalogue', {
      'generation': 2,
      'revision': 1,
      'sessions': [
        {
          'id': 'pc',
          'ownerId': 'jonas',
          'source': 'laptop',
          'destination': 'house',
          'state': 'playing',
          'eligible': true,
          'claimSequence': 3,
        },
      ],
    });
    controller.receive('Receivers', {
      'generation': 2,
      'revision': 1,
      'receivers': [
        {
          'speakerId': 'office',
          'online': true,
          'status': {
            'selected': ['pc'],
            'audible': ['pc'],
            'reasons': {'pc': 'selected'},
          },
        },
        {
          'speakerId': 'kitchen',
          'online': true,
          'status': {
            'selected': <Object>[],
            'audible': <Object>[],
            'reasons': {'pc': 'source disabled'},
          },
        },
      ],
    });
    mqtt.commands.clear();
  });

  tearDown(() async {
    controller.dispose();
    await Hive.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: syrenTheme(),
        home: ProfileShell(
          controller: controller,
          positioning: PositioningControls(
            isMeasuring: () => false,
            toggle: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('without a profile the picker continues as the chosen person', (
    tester,
  ) async {
    await open(tester);
    expect(find.text("Who's listening?"), findsOneWidget);
    expect(find.text('Playing in Office'), findsOneWidget);
    await tester.tap(find.text('Jonas'));
    await tester.pump();
    await tester.tap(find.text('Continue as Jonas'));
    await tester.pumpAndSettle();
    final select = mqtt.commands.where(
      (command) => command['action'] == 'select',
    );
    expect(select.single['profileId'], 'jonas');
    expect(find.text('1 of 2 rooms playing'), findsOneWidget);
  });

  testWidgets('a silent room explains itself and applies the fix', (
    tester,
  ) async {
    controller.selectedId = 'maya';
    await open(tester);
    expect(find.text('Office'), findsOneWidget);
    expect(find.text('PC audio is off here ›'), findsOneWidget);

    await tester.tap(find.text('Kitchen'));
    await tester.pumpAndSettle();
    expect(find.text("Why it's quiet"), findsOneWidget);
    expect(
      find.text("Jonas' PC audio is playing, but PC audio is off in this room"),
      findsOneWidget,
    );
    await tester.tap(find.text('Turn on PC audio here'));
    await tester.pumpAndSettle();
    final change = mqtt.commands.singleWhere(
      (command) => command['action'] == 'group',
    );
    expect(change['groupId'], 'kitchen-room');
    expect(change['enabledSources'], containsAll(['spotify', 'laptop']));
    expect(change['masterVolume'], 48);
  });

  testWidgets('a new room is saved with its chosen speakers', (tester) async {
    controller.selectedId = 'maya';
    await open(tester);
    await tester.tap(find.text('Rooms'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ New room'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Terrace');
    await tester.tap(find.text('Kitchen speaker'));
    await tester.pump();
    expect(find.text('1 speaker selected'.toUpperCase()), findsOneWidget);
    expect(find.text('Also in Kitchen'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = mqtt.commands.singleWhere(
      (command) => command['action'] == 'group',
    );
    expect(saved['groupId'], isNull);
    expect(saved['name'], 'Terrace');
    expect(saved['speakerIds'], ['kitchen']);
    expect(saved['muted'], isFalse);
  });

  testWidgets('allowing a mix saves the pair on my profile only', (
    tester,
  ) async {
    controller.selectedId = 'maya';
    await open(tester);
    await tester.tap(find.text('Rules'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mix').first);
    await tester.pumpAndSettle();
    final saved = mqtt.commands.singleWhere(
      (command) => command['action'] == 'profile',
    );
    expect(saved['profile']['id'], 'maya');
    expect(saved['profile']['overlap'], [
      {'first': 'laptop', 'second': 'spotify'},
    ]);
  });

  testWidgets('the home volume changes the room master volume', (tester) async {
    controller.selectedId = 'maya';
    await open(tester);
    final slider = find.byType(Slider).first;
    await tester.drag(slider, const Offset(-400, 0));
    await tester.pumpAndSettle();
    final volume = mqtt.commands.lastWhere(
      (command) => command['action'] == 'group',
    );
    expect(volume['groupId'], 'office-room');
    expect(volume['masterVolume'], 0);
  });
}
