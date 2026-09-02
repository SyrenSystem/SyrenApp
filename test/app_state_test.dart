import 'dart:io';

import 'package:final_project/models/distance_item.dart';
import 'package:final_project/models/server_status.dart';
import 'package:final_project/providers/app_state_providers.dart';
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

  test('the same server state keeps local intent, adopts unknown speakers '
      'and drops stale disconnected entries', () async {
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

    expect(result, {'keep': true, 'server-speaker': true});
  });

  test(
    'a disconnected entry the server still lists is kept until it disappears',
    () async {
      await connectionsBox.putAll({'leaving': false});
      await metadataBox.put('server_state_id', 'state');
      final notifier = DesiredSpeakerConnectionsNotifier(
        connectionsBox,
        metadataBox,
      );

      final stillListed = await notifier.reconcileStatus(
        const ServerStatus(
          sessionId: 'session',
          stateId: 'state',
          online: true,
          connectedSpeakerIds: {'leaving'},
        ),
      );
      final gone = await notifier.reconcileStatus(
        const ServerStatus(
          sessionId: 'session',
          stateId: 'state',
          online: true,
          connectedSpeakerIds: {},
        ),
      );

      expect(stillListed, {'leaving': false});
      expect(gone, isEmpty);
    },
  );

  test('forget removes the desired connection entry', () async {
    await connectionsBox.putAll({'aa:bb': true});
    final notifier = DesiredSpeakerConnectionsNotifier(
      connectionsBox,
      metadataBox,
    );

    await notifier.forget('AA:BB');

    expect(notifier.state, isEmpty);
  });

  test('sensor display name prefers the configured speaker name', () {
    final item = DistanceItem(id: 'aa:bb', label: 'Old label');

    expect(sensorDisplayName({'aa:bb': 'Kitchen'}, item), 'Kitchen');
  });

  test('falls back to the local label unless it is unknown', () {
    expect(
      sensorDisplayName(const {}, DistanceItem(id: 'aa:bb', label: 'Desk')),
      'Desk',
    );
    expect(sensorDisplayName(const {}, DistanceItem(id: 'aa:bb')), isNull);
  });
}
