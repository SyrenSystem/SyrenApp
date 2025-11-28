
import 'dart:convert';

import 'package:final_project/communication/mqtt.dart';

class DistanceSender {
  late MQTTClient _mqttClient;

  DistanceSender( MQTTClient mqttClient) {
    _mqttClient = mqttClient;
  }

  bool sendDistance(String rawDistanceData, [String topic = "SyrenSystem/SyrenApp/sensorData"]) {
    Map<String, dynamic> distanceData = jsonDecode(rawDistanceData);
    final dataToSend =
        [
          {
            "id": distanceData["id"],
            "distance": distanceData['distance']
          }
        ];

    final jsonToSend = jsonEncode(dataToSend);

    _mqttClient.publish(topic, jsonToSend);
    return true;
  }
}