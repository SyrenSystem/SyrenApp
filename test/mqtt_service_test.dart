import 'package:final_project/models/server_status.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/syren_topics.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test(
    'validates outbound distance and volume boundaries before connection',
    () {
      final service = MqttService(clientId: 'test-client');

      expect(service.sendDistance('', 1), isFalse);
      expect(service.sendDistance('sensor', -1), isFalse);
      expect(service.sendDistance('sensor', double.nan), isFalse);
      expect(service.sendConnect('sensor', 101), isFalse);
      expect(service.sendVolumeUpdate('sensor', double.infinity), isFalse);
    },
  );
}
