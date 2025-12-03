import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models/speaker.dart';

class MqttService {
  MqttServerClient? _client;
  bool _connected = false;

  Function(Map<String, dynamic>)? onUserPositionReceived;
  Function(String, Map<String, dynamic>)? onSpeakerPositionReceived;

  bool get isConnected => _connected;

  Future<bool> connect(String ip, [int port = 1883]) async {
    if (_connected) {
      return false;
    }

    _client = MqttServerClient(ip, 'SyrenApp');
    _client!.port = port;
    _client!.logging(on: false);
    _client!.keepAlivePeriod = 20;

    _client!.onDisconnected = () {
      _connected = false;
      print('Disconnected from broker');
    };

    _client!.onConnected = () {
      _connected = true;
      print('Connected to broker');
    };

    _client!.onSubscribed = (String topic) {
      print('Subscribed to topic: $topic');
    };

    final connMess = MqttConnectMessage()
        .withClientIdentifier('SyrenApp')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    _client!.connectionMessage = connMess;

    try {
      await _client!.connect();
    } catch (e) {
      print('Exception: $e');
      _client!.disconnect();
      return false;
    }

    // Set up message received callback
    _client!.updates!.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (final message in messages) {
        final recMess = message.payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        _handleMessage(message.topic, payload);
      }
    });

    // Subscribe to position topics
    _client!.subscribe('SyrenSystem/SyrenServer/GetUserPosition', MqttQos.atLeastOnce);
    _client!.subscribe('SyrenSystem/SyrenServer/GetSpeakerPosition', MqttQos.atLeastOnce);

    return true;
  }

  void disconnect() {
    if (_connected && _client != null) {
      _client!.disconnect();
      _connected = false;
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

  bool sendDistance(String rawDistanceData,
      [String topic = "SyrenSystem/SyrenApp/UpdateDistance"]) {
    Map<String, dynamic> distanceData = jsonDecode(rawDistanceData);
    final dataToSend =
    {
      "id": distanceData["id"],
      "distance": distanceData['distance']
    }
    ;

    final jsonToSend = jsonEncode(dataToSend);
    if (_connected) {
      publish(topic, jsonToSend);
      return true;
    }
    return false;
  }

  bool connectSpeaker(String speakerMacAddress) {
    String topic = "SyrenSystem/SyrenApp/ConnectSpeaker";

    final toSendData = {
      "id": speakerMacAddress
    };
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

    final toSendData = {"id": id};
    final jsonToSend = jsonEncode(toSendData);
    if (_connected) {
      publish(topic, jsonToSend);
      return true;
    }
    return false;
  }

  sendVolumeUpdate(String identifier, double value)
  {
    final String topic = "SyrenSystem/SyrenApp/SetSpeakerVolume";
    final toSendData = {
      "id": identifier,
      "volume": value.toInt()
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
          onSpeakerPositionReceived?.call(data['id'], data['position']);
        }
      }
    } catch (e) {
      print('Error handling MQTT message: $e');
    }
  }
}
