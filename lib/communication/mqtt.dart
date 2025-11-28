import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

Future<void> main() async {
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
  builder.addString('Hello from Flutter MQTT!');
  client.publishMessage(topic, MqttQos.exactlyOnce, builder.payload!);

  // Wait a bit then disconnect
  await Future.delayed(Duration(seconds: 5));
  client.disconnect();
}

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
