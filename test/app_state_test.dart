import 'dart:io';

import 'package:final_project/models/distance_item.dart';
import 'package:final_project/models/server_status.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/volume_commit_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory hiveDirectory;
  late Box<DistanceItem> distanceBox;
  late Box<bool> connectionsBox;
  late Box<String> metadataBox;

  setUpAll(() async {
    hiveDirectory = Directory.systemTemp.createTempSync('syren_state_test_');
    Hive.init(hiveDirectory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DistanceItemAdapter());
    }
    distanceBox = await Hive.openBox<DistanceItem>('state_distance_items');
    connectionsBox = await Hive.openBox<bool>('state_connections');
    metadataBox = await Hive.openBox<String>('state_metadata');
  });

  setUp(() async {
    await distanceBox.clear();
    await connectionsBox.clear();
    await metadataBox.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    hiveDirectory.deleteSync(recursive: true);
  });

  test(
    'adding an existing sensor preserves preferences and reactivates it',
    () async {
      final saved = DistanceItem(
        id: 'sensor',
        distance: 10,
        active: false,
        volume: 42,
        label: 'Kitchen',
      );
      await distanceBox.put(saved.id, saved);
      final notifier = DistanceItemsNotifier(distanceBox);

      notifier.add(DistanceItem(id: 'sensor', distance: 25));

      expect(notifier.state.single.distance, 25);
      expect(notifier.state.single.active, isTrue);
      expect(notifier.state.single.volume, 42);
      expect(notifier.state.single.label, 'Kitchen');
    },
  );

  test('a new server state adopts its connected speakers', () async {
    await connectionsBox.putAll({'old': true, 'remove': false});
    await metadataBox.put('server_state_id', 'old-state');
    final notifier = DesiredSpeakerConnectionsNotifier(
      connectionsBox,
      metadataBox,
    );

    final result = await notifier.reconcileStatus(
      const ServerStatus(
        sessionId: 'session',
        stateId: 'new-state',
        online: true,
        connectedSpeakerIds: {'server-speaker'},
      ),
    );

    expect(result, {'server-speaker': true});
    expect(notifier.stateId, 'new-state');
  });

  test(
    'the same server state keeps local intent and adopts unknown speakers',
    () async {
      await connectionsBox.putAll({'keep': true, 'remove': false});
      await metadataBox.put('server_state_id', 'state');
      final notifier = DesiredSpeakerConnectionsNotifier(
        connectionsBox,
        metadataBox,
      );

      final result = await notifier.reconcileStatus(
        const ServerStatus(
          sessionId: 'session',
          stateId: 'state',
          online: true,
          connectedSpeakerIds: {'server-speaker'},
        ),
      );

      expect(result, {'keep': true, 'remove': false, 'server-speaker': true});
    },
  );

  test('volume changes coalesce into one persisted publish', () async {
    final item = DistanceItem(id: 'sensor', distance: 10);
    await distanceBox.put(item.id, item);
    final distanceItems = DistanceItemsNotifier(distanceBox);
    final mqttService = RecordingMqttService();
    final coordinator = VolumeCommitCoordinator(distanceItems, mqttService);

    coordinator.update('sensor', 10);
    coordinator.update('sensor', 20);
    coordinator.update('sensor', 30);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(distanceBox.get('sensor')?.volume, 30);
    expect(mqttService.volumeUpdates, [('sensor', 30)]);
    coordinator.dispose();
  });
}

class RecordingMqttService extends MqttService {
  RecordingMqttService() : super(clientId: 'test-client');

  final List<(String, double)> volumeUpdates = [];

  @override
  bool sendVolumeUpdate(String id, double volume) {
    volumeUpdates.add((id, volume));
    return true;
  }
}
