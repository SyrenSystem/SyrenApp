import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:final_project/models/server_status.dart';
import 'package:final_project/services/syren_topics.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttService {
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>?
  _updatesSubscription;
  bool _connected = false;
  String? _connectedHost;
  int? _connectedPort;
  int _connectionVersion = 0;

  MqttService({String? clientId}) : clientId = clientId ?? _createClientId();

  final String clientId;
  void Function(Map<String, dynamic>)? onUserPositionReceived;
  VoidCallback? onUserPositionCleared;
  void Function(String, Map<String, dynamic>)? onSpeakerPositionReceived;
  void Function(String)? onSpeakerRemoved;
  void Function(ServerStatus)? onServerStatus;

  bool get isConnected => _connected;
  String? get connectedHost => _connectedHost;
  int? get connectedPort => _connectedPort;

  Future<bool> connect(String brokerHost, [int port = 1883]) async {
    if (_connected && _connectedHost == brokerHost && _connectedPort == port) {
      return true;
    }

    final connectionVersion = ++_connectionVersion;
    await _disconnectCurrentClient();
    final client = MqttServerClient(brokerHost, clientId)
      ..port = port
      ..keepAlivePeriod = 20
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true;
    client.logging(on: false);
    _client = client;
    _connectedHost = brokerHost;
    _connectedPort = port;

    client.onDisconnected = () {
      if (identical(_client, client)) {
        _connected = false;
        debugPrint('Disconnected from MQTT broker');
      }
    };
    client.onConnected = () {
      if (identical(_client, client)) {
        _connected = true;
        debugPrint('Connected to MQTT broker');
      }
    };
    client.onAutoReconnect = () {
      if (identical(_client, client)) {
        _connected = false;
      }
    };
    client.onAutoReconnected = () {
      if (identical(_client, client)) {
        _connected = true;
      }
    };
    client.onSubscribed = (topic) => debugPrint('Subscribed to $topic');
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    try {
      await client.connect();
    } catch (error) {
      debugPrint('MQTT connection failed: $error');
      if (identical(_client, client) &&
          connectionVersion == _connectionVersion) {
        await _disconnectCurrentClient();
      }
      return false;
    }

    if (!identical(_client, client) ||
        connectionVersion != _connectionVersion ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      client.autoReconnect = false;
      client.disconnect();
      return false;
    }

    _updatesSubscription = client.updates!.listen(
      (messages) {
        for (final message in messages) {
          final mqttMessage = message.payload as MqttPublishMessage;
          final payload = MqttPublishPayload.bytesToStringAsString(
            mqttMessage.payload.message,
          );
          handleMessage(message.topic, payload);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('MQTT message stream failed: $error');
      },
    );
    client.subscribe('${SyrenTopics.speakerPosition}/#', MqttQos.atLeastOnce);
    client.subscribe(SyrenTopics.userPosition, MqttQos.atMostOnce);
    client.subscribe(SyrenTopics.serverStatus, MqttQos.atLeastOnce);
    return true;
  }

  Future<void> disconnect() async {
    _connectionVersion++;
    await _disconnectCurrentClient();
  }

  bool publish(
    String topic,
    Object message, {
    MqttQos qos = MqttQos.atLeastOnce,
  }) {
    final client = _client;
    if (!_connected || client == null) {
      return false;
    }
    try {
      final builder = MqttClientPayloadBuilder()
        ..addString(jsonEncode(message));
      client.publishMessage(topic, qos, builder.payload!);
      return true;
    } catch (error) {
      debugPrint('MQTT publish failed for $topic: $error');
      return false;
    }
  }

  bool sendDistance(String id, double distance) {
    if (id.trim().isEmpty || !distance.isFinite || distance < 0) {
      return false;
    }
    return publish(SyrenTopics.updateDistance, {
      'id': id.toLowerCase(),
      'distance': distance,
    }, qos: MqttQos.atMostOnce);
  }

  bool sendConnect(String id, double volume) {
    if (!_validVolume(id, volume)) {
      return false;
    }
    return publish(SyrenTopics.connectSpeaker, {
      'id': id.toLowerCase(),
      'volume': volume,
    });
  }

  bool sendDisconnect(String id) {
    if (id.trim().isEmpty) {
      return false;
    }
    return publish(SyrenTopics.disconnectSpeaker, {'id': id.toLowerCase()});
  }

  bool sendVolumeUpdate(String id, double volume) {
    if (!_validVolume(id, volume)) {
      return false;
    }
    return publish(SyrenTopics.setSpeakerVolume, {
      'id': id.toLowerCase(),
      'volume': volume,
    });
  }

  @visibleForTesting
  void handleMessage(String topic, String payload) {
    if (topic == SyrenTopics.userPosition && payload.isEmpty) {
      onUserPositionCleared?.call();
      return;
    }

    final speakerPrefix = '${SyrenTopics.speakerPosition}/';
    if (topic.startsWith(speakerPrefix)) {
      final suffix = topic.substring(speakerPrefix.length);
      if (suffix.isEmpty || suffix.contains('/')) {
        return;
      }
      final sensorId = suffix.toLowerCase();
      if (payload.isEmpty) {
        onSpeakerRemoved?.call(sensorId);
        return;
      }
      final data = _decodeMap(payload);
      final payloadId = data?['id'];
      final position = data?['position'];
      if (payloadId is String &&
          payloadId.toLowerCase() == sensorId &&
          position is Map<String, dynamic> &&
          _validPosition(position)) {
        onSpeakerPositionReceived?.call(sensorId, position);
      }
      return;
    }

    final data = _decodeMap(payload);
    if (data == null) {
      return;
    }
    if (topic == SyrenTopics.userPosition) {
      final position = data['position'];
      if (position is Map<String, dynamic> && _validPosition(position)) {
        onUserPositionReceived?.call(position);
      }
      return;
    }
    if (topic == SyrenTopics.serverStatus) {
      final sessionId = data['sessionId'];
      final stateId = data['stateId'];
      final online = data['online'];
      final rawSpeakerIds = data['connectedSpeakerIds'];
      if (sessionId is! String ||
          sessionId.isEmpty ||
          stateId is! String ||
          stateId.isEmpty ||
          online is! bool ||
          (rawSpeakerIds != null && rawSpeakerIds is! List)) {
        return;
      }
      final speakerIds = <String>{};
      if (rawSpeakerIds is List) {
        for (final speakerId in rawSpeakerIds) {
          if (speakerId is! String || speakerId.isEmpty) {
            return;
          }
          speakerIds.add(speakerId.toLowerCase());
        }
      }
      onServerStatus?.call(
        ServerStatus(
          sessionId: sessionId,
          stateId: stateId,
          online: online,
          connectedSpeakerIds: speakerIds,
        ),
      );
    }
  }

  Future<void> _disconnectCurrentClient() async {
    final client = _client;
    _client = null;
    _connected = false;
    _connectedHost = null;
    _connectedPort = null;
    await _updatesSubscription?.cancel();
    _updatesSubscription = null;
    if (client != null) {
      client.autoReconnect = false;
      client.disconnect();
    }
  }

  Map<String, dynamic>? _decodeMap(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  bool _validVolume(String id, double volume) =>
      id.trim().isNotEmpty && volume.isFinite && volume >= 0 && volume <= 100;

  bool _validPosition(Map<String, dynamic> position) {
    for (final coordinateName in const ['x', 'y', 'z']) {
      final coordinate = position[coordinateName];
      if (coordinate is! num || !coordinate.toDouble().isFinite) {
        return false;
      }
    }
    return true;
  }

  static String _createClientId() {
    final randomPart = Random.secure()
        .nextInt(0x100000000)
        .toRadixString(16)
        .padLeft(8, '0');
    final timePart = (DateTime.now().microsecondsSinceEpoch & 0xffff)
        .toRadixString(16)
        .padLeft(4, '0');
    return 'SyrenApp-$randomPart-$timePart';
  }
}
