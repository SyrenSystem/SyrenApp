import 'package:final_project/models/server_status.dart';
import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/syren_topics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';

const validConfigurationJson =
    '{"stateId":"state","revision":3,"speakers":['
    '{"id":"speaker","name":"Desk","snapClientId":"client",'
    '"sensorId":null,"fullVolumeDistance":1000,"muteDistance":5000,'
    '"level":75,"calibrated":false}],"groups":['
    '{"id":"desk","name":"Desk","speakerIds":["speaker"],'
    '"sourcePriority":["laptop","spotify"],"volumeMode":"manual",'
    '"masterVolume":80,"muted":false}],"sources":['
    '{"id":"spotify","name":"Spotify"},'
    '{"id":"laptop","name":"Laptop audio"}]}';

void main() {
  test('accepts a speaker position only on its matching subtopic', () {
    final service = MqttService(clientId: 'test-client');
    final positions = <(String, Map<String, dynamic>)>[];
    service.onSpeakerPositionReceived = (id, position) {
      positions.add((id, position));
    };

    service.handleMessage(
      '${SyrenTopics.speakerPosition}/aa:bb',
      '{"id":"AA:BB","position":{"x":1,"y":2,"z":3}}',
    );
    service.handleMessage(
      '${SyrenTopics.speakerPosition}/cc:dd',
      '{"id":"AA:BB","position":{"x":1,"y":2,"z":3}}',
    );
    service.handleMessage(
      SyrenTopics.speakerPosition,
      '{"id":"AA:BB","position":{"x":1,"y":2,"z":3}}',
    );

    expect(positions, hasLength(1));
    expect(positions.single.$1, 'aa:bb');
    expect(positions.single.$2, {'x': 1, 'y': 2, 'z': 3});
  });

  test('empty speaker subtopic removes that speaker', () {
    final service = MqttService(clientId: 'test-client');
    String? removedId;
    service.onSpeakerRemoved = (id) => removedId = id;

    service.handleMessage('${SyrenTopics.speakerPosition}/AA:BB', '');

    expect(removedId, 'aa:bb');
  });

  test('parses the server status contract', () {
    final service = MqttService(clientId: 'test-client');
    ServerStatus? status;
    service.onServerStatus = (value) => status = value;

    service.handleMessage(
      SyrenTopics.serverStatus,
      '{"sessionId":"session","stateId":"state","online":true,'
      '"connectedSpeakerIds":["AA:BB"]}',
    );

    expect(status?.sessionId, 'session');
    expect(status?.stateId, 'state');
    expect(status?.online, isTrue);
    expect(status?.connectedSpeakerIds, {'aa:bb'});
  });

  test('rejects malformed status and position messages', () {
    final service = MqttService(clientId: 'test-client');
    var callbackCount = 0;
    service.onServerStatus = (_) => callbackCount++;
    service.onSpeakerPositionReceived = (speakerId, position) {
      callbackCount++;
    };

    service.handleMessage(SyrenTopics.serverStatus, '{"online":true}');
    service.handleMessage(
      '${SyrenTopics.speakerPosition}/aa:bb/extra',
      '{"id":"aa:bb","position":{}}',
    );
    service.handleMessage(
      SyrenTopics.userPosition,
      '{"position":{"x":"bad","y":2,"z":3}}',
    );

    expect(callbackCount, 0);
  });

  test('parses configuration and runtime contracts', () {
    final service = MqttService(clientId: 'test-client');
    SystemConfiguration? configuration;
    SystemRuntime? runtime;
    service.onConfiguration = (value) => configuration = value;
    service.onRuntime = (value) => runtime = value;

    service.handleMessage(SyrenTopics.configuration, validConfigurationJson);
    service.handleMessage(
      SyrenTopics.runtime,
      '{"onlineSnapClients":[{"id":"client","name":"Desk Pi"}],'
      '"sources":[{"id":"laptop","active":true}]}',
    );

    expect(configuration?.revision, 3);
    expect(configuration?.speakers.single.sensorId, isNull);
    expect(configuration?.groups.single.sourcePriority, ['laptop', 'spotify']);
    expect(configuration?.groups.single.automatic, isFalse);
    expect(runtime?.onlineSnapClients.single.name, 'Desk Pi');
    expect(runtime?.sources.single.active, isTrue);
    expect(runtime?.snapserverOnline, isTrue);
  });

  test('runtime reports an offline snapserver', () {
    final service = MqttService(clientId: 'test-client');
    SystemRuntime? runtime;
    service.onRuntime = (value) => runtime = value;

    service.handleMessage(
      SyrenTopics.runtime,
      '{"onlineSnapClients":[],"sources":[],"snapserverOnline":false}',
    );

    expect(runtime?.snapserverOnline, isFalse);
    expect(runtime?.onlineSnapClients, isEmpty);
  });

  test('parses command results from request subtopics', () {
    final service = MqttService(clientId: 'test-client');
    CommandResult? result;
    service.onCommandResult = (value) => result = value;

    service.handleMessage(
      '${SyrenTopics.commandResult}/request',
      '{"requestId":"request","success":false,"revision":7,'
          '"error":"Configuration changed"}',
    );

    expect(result?.requestId, 'request');
    expect(result?.success, isFalse);
    expect(result?.revision, 7);
    expect(result?.error, 'Configuration changed');
  });

  test('sendConnect publishes only the lowercase sensor id', () {
    final service = RecordingPublishMqttService();

    expect(service.sendConnect('AA:BB'), isTrue);

    expect(service.published, hasLength(1));
    expect(service.published.single.$1, SyrenTopics.connectSpeaker);
    expect(service.published.single.$2, {'id': 'aa:bb'});
  });

  test('malformed configuration is logged and later messages still arrive', () {
    final service = MqttService(clientId: 'test-client');
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };
    addTearDown(() => debugPrint = originalDebugPrint);
    var configurationCount = 0;
    service.onConfiguration = (_) => configurationCount++;

    service.handleMessage(SyrenTopics.configuration, '{"stateId":"s"}');
    service.handleMessage(SyrenTopics.configuration, validConfigurationJson);

    expect(logs, hasLength(1));
    expect(logs.single, contains(SyrenTopics.configuration));
    expect(configurationCount, 1);
  });

  test('validates outbound ids and distances before connection', () {
    final service = MqttService(clientId: 'test-client');

    expect(service.sendDistance('', 1), isFalse);
    expect(service.sendDistance('sensor', -1), isFalse);
    expect(service.sendDistance('sensor', double.nan), isFalse);
    expect(service.sendConnect(''), isFalse);
    expect(service.sendDisconnect(' '), isFalse);
  });
}

class RecordingPublishMqttService extends MqttService {
  RecordingPublishMqttService() : super(clientId: 'test-client');

  final List<(String, Object)> published = [];

  @override
  bool publish(
    String topic,
    Object message, {
    MqttQos qos = MqttQos.atLeastOnce,
  }) {
    published.add((topic, message));
    return true;
  }
}
