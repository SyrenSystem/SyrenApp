import 'dart:async';
import 'dart:io';

import 'package:final_project/models/distance_item.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/measurement_provider.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/providers/settings_provider.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/serial_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory hiveDirectory;

  setUpAll(() async {
    hiveDirectory = Directory.systemTemp.createTempSync('syren_app_test_');
    Hive.init(hiveDirectory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DistanceItemAdapter());
    }
  });

  setUp(() async {
    final distanceBox = await Hive.openBox<DistanceItem>('distance_items');
    await distanceBox.clear();
    final connectionsBox = await Hive.openBox<bool>('speaker_connections');
    await connectionsBox.clear();
    final metadataBox = await Hive.openBox<String>('syren_metadata');
    await metadataBox.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    hiveDirectory.deleteSync(recursive: true);
  });

  test('MQTT client IDs are unique per service instance', () {
    final firstService = MqttService();
    final secondService = MqttService();

    expect(firstService.clientId, startsWith('SyrenApp-'));
    expect(secondService.clientId, startsWith('SyrenApp-'));
    expect(firstService.clientId, isNot(secondService.clientId));
    expect(firstService.clientId.length, lessThanOrEqualTo(23));
  });

  test(
    'saved settings connect MQTT and receive positions without serial',
    () async {
      SharedPreferences.setMockInitialValues({
        'ip': 'broker-one',
        'port': 1883,
      });
      final mqttService = FakeMqttService();
      final serialService = FakeSerialService(connectResult: false);
      final container = ProviderContainer(
        overrides: [
          mqttServiceProvider.overrideWithValue(mqttService),
          serialServiceProvider.overrideWithValue(serialService),
        ],
      );
      addTearDown(container.dispose);
      final connectionSubscription = container.listen(
        mqttConnectionProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(connectionSubscription.close);

      await waitUntil(() => mqttService.connectedEndpoints.isNotEmpty);
      mqttService.onUserPositionReceived?.call({'x': 1, 'y': 2, 'z': 3});

      expect(mqttService.connectedEndpoints.single, ('broker-one', 1883));
      expect(container.read(userPositionProvider)?.x, 1);
      expect(serialService.connectCalls, 0);

      await container
          .read(settingsProvider.notifier)
          .saveSettings('broker-two', 2883);
      await waitUntil(() => mqttService.connectedEndpoints.length == 2);
      expect(mqttService.connectedEndpoints.last, ('broker-two', 2883));
    },
  );

  test('failed initial MQTT connections retry until successful', () async {
    SharedPreferences.setMockInitialValues({
      'ip': 'recovering-broker',
      'port': 1883,
    });
    final mqttService = FakeMqttService(
      connectionResults: [false, false, true],
    );
    final serialService = FakeSerialService(connectResult: false);
    final container = ProviderContainer(
      overrides: [
        mqttServiceProvider.overrideWithValue(mqttService),
        serialServiceProvider.overrideWithValue(serialService),
        mqttConnectionRetryDelayProvider.overrideWithValue(
          const Duration(milliseconds: 10),
        ),
      ],
    );
    addTearDown(container.dispose);
    final connectionSubscription = container.listen(
      mqttConnectionProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    addTearDown(connectionSubscription.close);

    await waitUntil(
      () =>
          mqttService.connectedEndpoints.length == 3 && mqttService.isConnected,
    );

    expect(
      mqttService.connectedEndpoints,
      List.filled(3, ('recovering-broker', 1883)),
    );
  });

  test('serial open failure keeps the MQTT observer connected', () async {
    final mqttService = FakeMqttService();
    final serialService = FakeSerialService(connectResult: false);
    final container = createContainer(mqttService, serialService);
    addTearDown(container.dispose);

    final error = await container
        .read(measurementControllerProvider)
        .startMeasurement();

    expect(error, 'Could not open the USB sensor.');
    expect(mqttService.disconnectCalls, 0);
    expect(mqttService.isConnected, isTrue);
  });

  test('missing serial device keeps the MQTT observer connected', () async {
    final mqttService = FakeMqttService();
    final serialService = FakeSerialService(
      connectResult: false,
      availableDevices: [],
    );
    final container = createContainer(mqttService, serialService);
    addTearDown(container.dispose);

    final error = await container
        .read(measurementControllerProvider)
        .startMeasurement();

    expect(error, 'No USB sensor detected.');
    expect(mqttService.disconnectCalls, 0);
    expect(mqttService.isConnected, isTrue);
  });

  test('first reading is stored and published', () async {
    final mqttService = FakeMqttService();
    final serialService = FakeSerialService(connectResult: true);
    final container = createContainer(mqttService, serialService);
    addTearDown(container.dispose);
    final controller = container.read(measurementControllerProvider);
    expect(await controller.startMeasurement(), isNull);

    serialService.onDistanceReceived?.call('sensor', 42.5);

    expect(mqttService.sentDistances, hasLength(1));
    expect(mqttService.sentDistances.single, ('sensor', 42.5));
    expect(container.read(distanceItemsProvider), hasLength(1));
    expect(container.read(distanceItemsProvider).single.id, 'sensor');

    await controller.stopMeasurement();
    expect(serialService.disconnectCalls, 1);
    expect(mqttService.disconnectCalls, 0);
  });

  test('speaker connection includes the saved volume', () async {
    final mqttService = FakeMqttService();
    final serialService = FakeSerialService(connectResult: true);
    final container = createContainer(mqttService, serialService);
    addTearDown(container.dispose);
    container
        .read(distanceItemsProvider.notifier)
        .add(DistanceItem(id: 'sensor', distance: 20, volume: 37));

    final connected = await container
        .read(measurementControllerProvider)
        .connectSpeaker('sensor');

    expect(connected, isTrue);
    expect(mqttService.connectRequests, [('sensor', 37)]);
    expect(container.read(desiredSpeakerConnectionsProvider), {'sensor': true});
  });
}

ProviderContainer createContainer(
  FakeMqttService mqttService,
  FakeSerialService serialService,
) {
  return ProviderContainer(
    overrides: [
      mqttServiceProvider.overrideWithValue(mqttService),
      serialServiceProvider.overrideWithValue(serialService),
      mqttConnectionProvider.overrideWith((ref) async => true),
    ],
  );
}

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class FakeMqttService extends MqttService {
  FakeMqttService({List<bool> connectionResults = const [true]})
    : _connectionResults = [...connectionResults],
      super(clientId: 'SyrenApp-test-client');

  final List<bool> _connectionResults;
  final List<(String, double)> sentDistances = [];
  final List<(String, double)> connectRequests = [];
  final List<String> disconnectRequests = [];
  final List<(String, double)> volumeUpdates = [];
  final List<(String, int)> connectedEndpoints = [];
  bool _isConnected = true;
  int disconnectCalls = 0;

  @override
  bool get isConnected => _isConnected;

  @override
  Future<bool> connect(String brokerHost, [int port = 1883]) async {
    connectedEndpoints.add((brokerHost, port));
    _isConnected = _connectionResults.isEmpty
        ? true
        : _connectionResults.removeAt(0);
    return _isConnected;
  }

  @override
  bool sendDistance(String id, double distance) {
    sentDistances.add((id, distance));
    return true;
  }

  @override
  bool sendConnect(String id, double volume) {
    connectRequests.add((id, volume));
    return _isConnected;
  }

  @override
  bool sendDisconnect(String id) {
    disconnectRequests.add(id);
    return _isConnected;
  }

  @override
  bool sendVolumeUpdate(String id, double volume) {
    volumeUpdates.add((id, volume));
    return _isConnected;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _isConnected = false;
  }
}

class FakeSerialService extends SerialService {
  FakeSerialService({
    required this.connectResult,
    this.availableDevices = const ['sensor'],
  });

  final bool connectResult;
  final List<String> availableDevices;
  bool connected = false;
  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  bool get isConnected => connected;

  @override
  Future<List<String>> getAvailableDevices() async => availableDevices;

  @override
  Future<bool> connect(String device) async {
    connectCalls++;
    connected = connectResult;
    return connectResult;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    connected = false;
  }
}
