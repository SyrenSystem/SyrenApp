import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MQTTClient {
  MqttServerClient? _client;
  bool _connected = false;
  Future<bool> connect(String ip, [int port = 1883]) async {
    if (_connected) {
      return false;
    }

    _client = MqttServerClient(ip, 'SyrenApp');
    _client!.port = port;
    _client!.logging(on: true);
    _client!.keepAlivePeriod = 20;
    // Callbacks
    void onConnected() {
      _connected = true;
      print('Connected to broker');
    }

    void onDisconnected() {
      _connected = false;
      print('Disconnected from broker');
    }

    void onSubscribed(String topic) {
      print('Subscribed to topic: $topic');
    }

    _client!.onDisconnected = onDisconnected;
    _client!.onConnected = onConnected;
    _client!.onSubscribed = onSubscribed;

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
    return true;
  }

  bool is_connected() {
    return _connected;
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
    if (!_connected || _client == null)
      {
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

  bool sendSpeakerConnectionInformation(String id, bool connected) {
    String topic;
    if (connected) {
      topic = "SyrenSystem/SyrenApp/ConnectSpeaker";
    }
    else {
      topic = "SyrenSystem/SyrenApp/DisconnectSpeaker";
    }

    final toSendData = {
      "id": id
    };
    final jsonToSend = jsonEncode(toSendData);
    if (_connected) {
      publish(topic, jsonToSend);
      return true;
    }
    return false;
  }
}

