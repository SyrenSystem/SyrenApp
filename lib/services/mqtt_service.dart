import 'dart:convert';
import 'dart:async';
import 'dart:math';

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
  final String clientId;

  Function(Map<String, dynamic>)? onUserPositionReceived;
  Function(String, Map<String, dynamic>)? onSpeakerPositionReceived;

  MqttService({String? clientId}) : clientId = clientId ?? _createClientId();

  bool get isConnected => _connected;
  String? get connectedHost => _connectedHost;
  int? get connectedPort => _connectedPort;

  Future<bool> connect(String brokerHost, [int port = 1883]) async {
    if (_connected && _connectedHost == brokerHost && _connectedPort == port) {
      return true;
    }

    final connectionVersion = ++_connectionVersion;
    await _disconnectCurrentClient();

    final client = MqttServerClient(brokerHost, clientId);
    _client = client;
    _connectedHost = brokerHost;
    _connectedPort = port;
    client.port = port;
    client.logging(on: false);
    client.keepAlivePeriod = 20;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;

    client.onDisconnected = () {
      if (identical(_client, client)) {
        _connected = false;
        print('Disconnected from broker');
      }
    };

    client.onConnected = () {
      if (identical(_client, client)) {
        _connected = true;
        print('Connected to broker');
      }
    };

    client.onAutoReconnect = () {
      if (identical(_client, client)) {
        _connected = false;
        print('Reconnecting to broker');
      }
    };

    client.onAutoReconnected = () {
      if (identical(_client, client)) {
        _connected = true;
        print('Reconnected to broker');
      }
    };

    client.onSubscribed = (String topic) {
      print('Subscribed to topic: $topic');
    };

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    client.connectionMessage = connMess;

    try {
      await client.connect();
    } catch (error) {
      print('Exception: $error');
      if (identical(_client, client) &&
          connectionVersion == _connectionVersion) {
        await _disconnectCurrentClient();
      }
      return false;
    }

    if (!identical(_client, client) ||
        connectionVersion != _connectionVersion) {
      client.autoReconnect = false;
      client.disconnect();
      return false;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      await _disconnectCurrentClient();
      return false;
    }

    _updatesSubscription = client.updates!.listen((
      List<MqttReceivedMessage<MqttMessage>> messages,
    ) {
      for (final message in messages) {
        final recMess = message.payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(
          recMess.payload.message,
        );
        _handleMessage(message.topic, payload);
      }
    });

    client.subscribe(
      'SyrenSystem/SyrenServer/GetUserPosition',
      MqttQos.atLeastOnce,
    );
    client.subscribe(
      'SyrenSystem/SyrenServer/GetSpeakerPosition',
      MqttQos.atLeastOnce,
    );

    return true;
  }

  Future<void> disconnect() async {
    _connectionVersion++;
    await _disconnectCurrentClient();
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

  bool publish(String topic, String message) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    if (!_connected || _client == null) {
      return false;
    }
    _client!.publishMessage(topic, MqttQos.exactlyOnce, builder.payload!);
    return true;
  }

  bool sendDistance(
    String rawDistanceData, [
    String topic = "SyrenSystem/SyrenApp/UpdateDistance",
  ]) {
    Map<String, dynamic> distanceData = jsonDecode(rawDistanceData);
    final dataToSend = {
      "id": distanceData["id"].toLowerCase(),
      "distance": distanceData['distance'],
    };

    final jsonToSend = jsonEncode(dataToSend);
    if (_connected) {
      publish(topic, jsonToSend);
      return true;
    }
    return false;
  }

  bool connectSpeaker(String speakerMacAddress) {
    String topic = "SyrenSystem/SyrenApp/ConnectSpeaker";

    final toSendData = {"id": speakerMacAddress.toLowerCase()};
    final jsonToSend = jsonEncode(toSendData);
    if (_connected) {
      publish(topic, jsonToSend);
      return true;
    }
    return false;
  }

  bool sendSpeakerConnectionInformation(String id, bool connected) {
    String topic;
    if (connected) {
      topic = "SyrenSystem/SyrenApp/ConnectSpeaker";
    } else {
      topic = "SyrenSystem/SyrenApp/DisconnectSpeaker";
    }

    final toSendData = {"id": id.toLowerCase()};
    final jsonToSend = jsonEncode(toSendData);
    if (_connected) {
      publish(topic, jsonToSend);
      return true;
    }
    return false;
  }

  sendVolumeUpdate(String identifier, double value) {
    final String topic = "SyrenSystem/SyrenApp/SetSpeakerVolume";
    final toSendData = {
      "id": identifier.toLowerCase(),
      "volume": value.toInt(),
    };
    publish(topic, jsonEncode(toSendData));
  }

  void _handleMessage(String topic, String payload) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;

      if (topic == 'SyrenSystem/SyrenServer/GetUserPosition') {
        if (data.containsKey('position')) {
          onUserPositionReceived?.call(data['position']);
        }
      } else if (topic == 'SyrenSystem/SyrenServer/GetSpeakerPosition') {
        if (data.containsKey('id') && data.containsKey('position')) {
          onSpeakerPositionReceived?.call(
            data['id'].toLowerCase(),
            data['position'],
          );
        }
      }
    } catch (e) {
      print('Error handling MQTT message: $e');
    }
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
