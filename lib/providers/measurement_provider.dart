import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/models/distance_item.dart';
import 'package:final_project/models/position_3d.dart';
import 'package:final_project/models/speaker_data.dart';

// Measurement Controller Provider
final measurementControllerProvider = Provider<MeasurementController>((ref) {
  return MeasurementController(ref);
});

class MeasurementController {
  final Ref ref;

  MeasurementController(this.ref);

  Future<String?> startMeasurement(String ip, int port) async {
    final mqttService = ref.read(mqttServiceProvider);
    final serialService = ref.read(serialServiceProvider);

    // Connect to MQTT
    if (!mqttService.isConnected && !await mqttService.connect(ip, port)) {
      return "Could not connect to MQTT.";
    }

    // Set up MQTT callbacks
    mqttService.onUserPositionReceived = (positionData) {
      ref.read(userPositionProvider.notifier).state = Position3D.fromJson(positionData);
    };

    mqttService.onSpeakerPositionReceived = (id, positionData) {
      final speakers = ref.read(speakersProvider.notifier);
      speakers.state = {
        ...speakers.state,
        id: SpeakerData(id: id, position: Position3D.fromJson(positionData)),
      };
    };

    // Set up serial callbacks
    serialService.onDistanceReceived = (id, distance) {
      final distanceItems = ref.read(distanceItemsProvider.notifier);

      // Update or add distance item
      final existingIndex = ref.read(distanceItemsProvider).indexWhere((item) => item.id == id);
      if (existingIndex != -1) {
        // Send distance via MQTT
        mqttService.sendDistance('{"id": "$id", "distance": $distance}');
        distanceItems.updateDistance(id, distance);
      } else {
        final newItem = DistanceItem(id: id, distance: distance, active: true);
        distanceItems.add(newItem);
      }
    };

    // Connect to serial device
    final devices = await serialService.getAvailableDevices();
    if (devices.isEmpty) {
      return "No USB sensor detected.";
    }

    await serialService.connect(devices.first);
    return null; // Success
  }

  void stopMeasurement() {
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

    // Disconnect services
    serialService.disconnect();
  }

  bool get isConnected {
    return ref.read(serialServiceProvider).isConnected;
  }
}
