import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MQTTClient {
  late MqttServerClient _client;
  bool _connected = false;

  MQTTClient(String ip, [int port = 1883]) {
    _client = MqttServerClient(ip, 'SyrenApp');
    _client.port = port;
    _client.logging(on: true);
    _client.keepAlivePeriod = 20;

    // Callbacks
    void onConnected() {
      print('Connected to broker');
    }

    void onDisconnected() {
      print('Disconnected from broker');
    }

    void onSubscribed(String topic) {
      print('Subscribed to topic: $topic');
    }

    _client.onDisconnected = onDisconnected;
    _client.onConnected = onConnected;
    _client.onSubscribed = onSubscribed;
  }

  Future<bool> connect() async {
    final connMess = MqttConnectMessage()
        .withClientIdentifier('SyrenApp')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    _client.connectionMessage = connMess;

    try {
      await _client.connect();
    } catch (e) {
      print('Exception: $e');
      _client.disconnect();
      return false;
    }
    _connected = true;
    return true;
  }

  bool is_connected() {
    return _connected;
  }

  void disconnect() {
    if (_connected) {
      _client.disconnect();
      _connected = false;
    }
  }


  void publish(String topic, String message) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    _client.publishMessage(topic, MqttQos.exactlyOnce, builder.payload!);
  }

  bool sendDistance(String rawDistanceData,
      [String topic = "SyrenSystem/SyrenApp/sensorData"]) {
    Map<String, dynamic> distanceData = jsonDecode(rawDistanceData);
    final dataToSend =
    [
      {
        "id": distanceData["id"],
        "distance": distanceData['distance']
      }
    ];

    final jsonToSend = jsonEncode(dataToSend);

    publish(topic, jsonToSend);
    return true;
  }
}

Future<void> main() async {

  // Callbacks
  void onConnected() {
    print('Connected to broker');
  }

  void onDisconnected() {
    print('Disconnected from broker');
  }

  void onSubscribed(String topic) {
    print('Subscribed to topic: $topic');
  }
  // Create client
  final client = MqttServerClient('localhost', 'flutter_client');

  client.port = 1883;
  client.logging(on: true);
  client.keepAlivePeriod = 20;
  client.onDisconnected = onDisconnected;
  client.onConnected = onConnected;
  client.onSubscribed = onSubscribed;

  // Connect
  final connMess = MqttConnectMessage()
      .withClientIdentifier('flutter_client')
      .startClean()
      .withWillQos(MqttQos.atLeastOnce);
  client.connectionMessage = connMess;

  try {
    await client.connect();
  } catch (e) {
    print('Exception: $e');
    client.disconnect();
    return;
  }

  // Subscribe to a topic
  const topic = 'flutter/mqtt';
  client.subscribe(topic, MqttQos.atMostOnce);

  // Listen for messages
  client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
    final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
    final pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

    print('Received message: $pt from topic: ${c[0].topic}');
  });

  // Publish a message
  final builder = MqttClientPayloadBuilder();
  builder.addString('Hello from Flutterpc MQTT!');
  client.publishMessage(topic, MqttQos.exactlyOnce, builder.payload!);

  // Wait a bit then disconnect
  await Future.delayed(Duration(seconds: 5));
  client.disconnect();

}

