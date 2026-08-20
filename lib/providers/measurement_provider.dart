import 'package:final_project/models/distance_item.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final measurementControllerProvider = Provider<MeasurementController>((ref) {
  return MeasurementController(ref);
});

class MeasurementController {
  MeasurementController(this.ref);

  final Ref ref;

  Future<String?> startMeasurement() async {
    final mqttService = ref.read(mqttServiceProvider);
    final serialService = ref.read(serialServiceProvider);
    if (!await ref.read(mqttConnectionProvider.future) ||
        !mqttService.isConnected) {
      return 'Could not connect to MQTT.';
    }

    serialService.onDistanceReceived = (id, distance) {
      ref
          .read(distanceItemsProvider.notifier)
          .add(DistanceItem(id: id, distance: distance, active: true));
      mqttService.sendDistance(id, distance);
    };
    final devices = await serialService.getAvailableDevices();
    if (devices.isEmpty) {
      serialService.onDistanceReceived = null;
      return 'No USB sensor detected.';
    }
    if (!await serialService.connect(devices.first)) {
      serialService.onDistanceReceived = null;
      return 'Could not open the USB sensor.';
    }
    return null;
  }

  Future<void> stopMeasurement() async {
    final mqttService = ref.read(mqttServiceProvider);
    final serialService = ref.read(serialServiceProvider);
    final items = List<DistanceItem>.of(ref.read(distanceItemsProvider));
    serialService.onDistanceReceived = null;
    await serialService.disconnect();
    for (final item in items) {
      await ref
          .read(desiredSpeakerConnectionsProvider.notifier)
          .setDesired(item.id, false);
      mqttService.sendDisconnect(item.id);
      ref.read(distanceItemsProvider.notifier).setInactive(item);
    }
  }

  Future<bool> connectSpeaker(String id) async {
    final item = ref.read(distanceItemsProvider.notifier).getById(id);
    if (item == null) {
      return false;
    }
    await ref
        .read(desiredSpeakerConnectionsProvider.notifier)
        .setDesired(id, true);
    return ref.read(mqttServiceProvider).sendConnect(id, item.volume);
  }

  bool get isConnected => ref.read(serialServiceProvider).isConnected;
}
