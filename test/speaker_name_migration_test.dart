import 'dart:io';

import 'package:final_project/models/distance_item.dart';
import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/speaker_name_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory hiveDirectory;
  late Box<DistanceItem> distanceBox;
  late Box<String> metadataBox;

  setUpAll(() async {
    hiveDirectory = Directory.systemTemp.createTempSync(
      'syren_migration_test_',
    );
    Hive.init(hiveDirectory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DistanceItemAdapter());
    }
    distanceBox = await Hive.openBox<DistanceItem>('migration_distance_items');
    metadataBox = await Hive.openBox<String>('migration_metadata');
  });

  setUp(() async {
    await distanceBox.clear();
    await metadataBox.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    hiveDirectory.deleteSync(recursive: true);
  });

  test(
    'pushes a local label once when the server name is the bare sensor id',
    () async {
      await distanceBox.put(
        'aa:bb',
        DistanceItem(id: 'aa:bb', label: 'Kitchen'),
      );
      final mqttService = ConfiguringMqttService();
      final migration = SpeakerNameMigration(
        DistanceItemsNotifier(distanceBox),
        metadataBox,
        mqttService,
      );
      final configuration = buildConfiguration(
        revision: 4,
        speakers: [
          buildSpeaker(id: 'speaker-1', name: 'AA:BB', sensorId: 'aa:bb'),
        ],
      );

      await migration.run(configuration);
      await migration.run(configuration);

      expect(mqttService.calls, hasLength(1));
      expect(mqttService.calls.single.speakerId, 'speaker-1');
      expect(mqttService.calls.single.name, 'Kitchen');
      expect(mqttService.calls.single.sensorId, 'aa:bb');
      expect(mqttService.calls.single.expectedRevision, 4);
      expect(
        metadataBox.get('${SpeakerNameMigration.pushedKeyPrefix}speaker-1'),
        isNotNull,
      );
    },
  );

  test('skips speakers that already have a name or no local label', () async {
    await distanceBox.put('aa:bb', DistanceItem(id: 'aa:bb', label: 'Other'));
    await distanceBox.put('ee:ff', DistanceItem(id: 'ee:ff'));
    final mqttService = ConfiguringMqttService();
    final migration = SpeakerNameMigration(
      DistanceItemsNotifier(distanceBox),
      metadataBox,
      mqttService,
    );

    await migration.run(
      buildConfiguration(
        revision: 1,
        speakers: [
          buildSpeaker(id: 'named', name: 'Kitchen', sensorId: 'aa:bb'),
          buildSpeaker(id: 'no-item', name: 'cc:dd', sensorId: 'cc:dd'),
          buildSpeaker(id: 'unknown-label', name: 'ee:ff', sensorId: 'ee:ff'),
          buildSpeaker(id: 'no-sensor', name: 'client', sensorId: null),
        ],
      ),
    );

    expect(mqttService.calls, isEmpty);
    expect(metadataBox.isEmpty, isTrue);
  });

  test('chains the revision from command results across speakers', () async {
    await distanceBox.put('aa:bb', DistanceItem(id: 'aa:bb', label: 'Kitchen'));
    await distanceBox.put('cc:dd', DistanceItem(id: 'cc:dd', label: 'Desk'));
    final mqttService = ConfiguringMqttService();
    final migration = SpeakerNameMigration(
      DistanceItemsNotifier(distanceBox),
      metadataBox,
      mqttService,
    );

    await migration.run(
      buildConfiguration(
        revision: 5,
        speakers: [
          buildSpeaker(id: 'first', name: 'aa:bb', sensorId: 'aa:bb'),
          buildSpeaker(id: 'second', name: 'cc:dd', sensorId: 'cc:dd'),
        ],
      ),
    );

    expect(mqttService.calls.map((call) => call.expectedRevision), [5, 6]);
    expect(mqttService.calls.map((call) => call.name), ['Kitchen', 'Desk']);
  });

  test('retries a push the server rejected', () async {
    await distanceBox.put('aa:bb', DistanceItem(id: 'aa:bb', label: 'Kitchen'));
    final mqttService = ConfiguringMqttService()..rejectedNames.add('Kitchen');
    final migration = SpeakerNameMigration(
      DistanceItemsNotifier(distanceBox),
      metadataBox,
      mqttService,
    );
    final configuration = buildConfiguration(
      revision: 2,
      speakers: [
        buildSpeaker(id: 'speaker-1', name: 'aa:bb', sensorId: 'aa:bb'),
      ],
    );

    await migration.run(configuration);
    expect(mqttService.calls, hasLength(1));
    expect(metadataBox.containsKey('label_pushed:speaker-1'), isFalse);

    mqttService.rejectedNames.clear();
    await migration.run(configuration);
    expect(mqttService.calls, hasLength(2));
    expect(metadataBox.get('label_pushed:speaker-1'), 'Kitchen');
  });

  test('keeps the marker when the outcome is unknown', () async {
    await distanceBox.put('aa:bb', DistanceItem(id: 'aa:bb', label: 'Kitchen'));
    await distanceBox.put('cc:dd', DistanceItem(id: 'cc:dd', label: 'Desk'));
    final mqttService = ConfiguringMqttService()..answerWithTimeout = true;
    final migration = SpeakerNameMigration(
      DistanceItemsNotifier(distanceBox),
      metadataBox,
      mqttService,
    );
    final configuration = buildConfiguration(
      revision: 2,
      speakers: [
        buildSpeaker(id: 'first', name: 'aa:bb', sensorId: 'aa:bb'),
        buildSpeaker(id: 'second', name: 'cc:dd', sensorId: 'cc:dd'),
      ],
    );

    await migration.run(configuration);
    expect(mqttService.calls.map((call) => call.name), ['Kitchen']);
    expect(metadataBox.containsKey('label_pushed:first'), isTrue);
    expect(metadataBox.containsKey('label_pushed:second'), isFalse);

    mqttService.answerWithTimeout = false;
    await migration.run(configuration);
    expect(mqttService.calls.map((call) => call.name), ['Kitchen', 'Desk']);
  });

  test('does nothing while disconnected', () async {
    await distanceBox.put('aa:bb', DistanceItem(id: 'aa:bb', label: 'Kitchen'));
    final mqttService = ConfiguringMqttService(connected: false);
    final migration = SpeakerNameMigration(
      DistanceItemsNotifier(distanceBox),
      metadataBox,
      mqttService,
    );

    await migration.run(
      buildConfiguration(
        revision: 1,
        speakers: [
          buildSpeaker(id: 'speaker-1', name: 'aa:bb', sensorId: 'aa:bb'),
        ],
      ),
    );

    expect(mqttService.calls, isEmpty);
    expect(metadataBox.isEmpty, isTrue);
  });
}

SystemConfiguration buildConfiguration({
  required int revision,
  required List<ConfiguredSpeaker> speakers,
}) {
  return SystemConfiguration(
    stateId: 'state',
    revision: revision,
    speakers: speakers,
    groups: const [],
    sources: const [],
  );
}

ConfiguredSpeaker buildSpeaker({
  required String id,
  required String name,
  required String? sensorId,
}) {
  return ConfiguredSpeaker(
    id: id,
    name: name,
    snapClientId: 'client-$id',
    sensorId: sensorId,
    fullVolumeDistance: 1000,
    muteDistance: 5000,
    level: 100,
    calibrated: false,
  );
}

class ConfigureCall {
  const ConfigureCall({
    required this.expectedRevision,
    required this.speakerId,
    required this.name,
    required this.sensorId,
  });

  final int expectedRevision;
  final String? speakerId;
  final String name;
  final String? sensorId;
}

class ConfiguringMqttService extends MqttService {
  ConfiguringMqttService({this.connected = true})
    : super(clientId: 'test-client');

  final bool connected;
  final List<ConfigureCall> calls = [];
  final Set<String> rejectedNames = {};
  bool answerWithTimeout = false;

  @override
  bool get isConnected => connected;

  @override
  Future<CommandResult?> configureSpeaker({
    required int expectedRevision,
    required String name,
    required String snapClientId,
    required String? sensorId,
    required double fullVolumeDistance,
    required double muteDistance,
    String? speakerId,
  }) async {
    calls.add(
      ConfigureCall(
        expectedRevision: expectedRevision,
        speakerId: speakerId,
        name: name,
        sensorId: sensorId,
      ),
    );
    if (answerWithTimeout) {
      return null;
    }
    if (rejectedNames.contains(name)) {
      return CommandResult(
        requestId: 'request-${calls.length}',
        success: false,
        revision: expectedRevision,
        error: 'Configuration changed; reload and try again',
      );
    }
    return CommandResult(
      requestId: 'request-${calls.length}',
      success: true,
      revision: expectedRevision + 1,
      error: null,
    );
  }
}
