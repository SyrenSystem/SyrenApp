import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/serial_service.dart';

// Service providers
final mqttServiceProvider = Provider<MqttService>((ref) {
  final service = MqttService();
  ref.onDispose(() {
    service.disconnect();
  });
  return service;
});

final serialServiceProvider = Provider<SerialService>((ref) {
  final service = SerialService();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
