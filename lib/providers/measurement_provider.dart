import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/models/distance_item.dart';

// Measurement Controller Provider
final measurementControllerProvider = Provider<MeasurementController>((ref) {
  return MeasurementController(ref);
});

class MeasurementController {
  final Ref ref;

  MeasurementController(this.ref);

  Future<String?> startMeasurement() async {
    final mqttService = ref.read(mqttServiceProvider);
    final serialService = ref.read(serialServiceProvider);

    if (!await ref.read(mqttConnectionProvider.future)) {
      return "Could not connect to MQTT.";
    }

    // Set up serial callbacks
    serialService.onDistanceReceived = (id, distance) {
      final distanceItems = ref.read(distanceItemsProvider.notifier);

      // Update or add distance item
      final existingIndex = ref
          .read(distanceItemsProvider)
          .indexWhere((item) => item.id == id);
      if (existingIndex != -1) {
        distanceItems.updateDistance(id, distance);
      } else {
        final newItem = DistanceItem(id: id, distance: distance, active: true);
        distanceItems.add(newItem);
      }

      mqttService.sendDistance('{"id": "$id", "distance": $distance}');
    };

    // Connect to serial device
    final devices = await serialService.getAvailableDevices();
    if (devices.isEmpty) {
      return "No USB sensor detected.";
    }

    if (!await serialService.connect(devices.first)) {
      return "Could not open the USB sensor.";
    }

    return null; // Success
  }

  Future<void> stopMeasurement() async {
    final mqttService = ref.read(mqttServiceProvider);
    final serialService = ref.read(serialServiceProvider);
    final distanceItems = ref.read(distanceItemsProvider);

    // Notify MQTT of speaker and set items inactive
    for (final item in distanceItems) {
      if (mqttService.isConnected) {
        mqttService.sendSpeakerConnectionInformation(item.id, false);
      }
      ref.read(distanceItemsProvider.notifier).setInactive(item);
    }

    // Clear state
    // ref.read(distanceItemsProvider.notifier).clear();

    await serialService.disconnect();
  }

  bool get isConnected {
    return ref.read(serialServiceProvider).isConnected;
  }
}
