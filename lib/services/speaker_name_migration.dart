import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:hive/hive.dart';

class SpeakerNameMigration {
  SpeakerNameMigration(this._distanceItems, this._metadata, this._mqttService);

  static const pushedKeyPrefix = 'label_pushed:';

  final DistanceItemsNotifier _distanceItems;
  final Box<String> _metadata;
  final MqttService _mqttService;
  bool _running = false;

  Future<void> run(SystemConfiguration configuration) async {
    if (_running || !_mqttService.isConnected) {
      return;
    }
    _running = true;
    try {
      var revision = configuration.revision;
      for (final speaker in configuration.speakers) {
        final sensorId = speaker.sensorId;
        if (sensorId == null ||
            speaker.name.toLowerCase() != sensorId.toLowerCase()) {
          continue;
        }
        final pushedKey = '$pushedKeyPrefix${speaker.id}';
        if (_metadata.containsKey(pushedKey)) {
          continue;
        }
        final item = _distanceItems.getById(sensorId.toLowerCase());
        final label = item?.label.trim() ?? '';
        if (label.isEmpty || label == 'unknown') {
          continue;
        }
        await _metadata.put(pushedKey, label);
        final result = await _mqttService.configureSpeaker(
          expectedRevision: revision,
          speakerId: speaker.id,
          name: label,
          snapClientId: speaker.snapClientId,
          sensorId: sensorId,
          fullVolumeDistance: speaker.fullVolumeDistance,
          muteDistance: speaker.muteDistance,
        );
        if (result == null) {
          // The outcome is unknown, so keep the marker and stop chaining revisions.
          return;
        }
        if (!result.success) {
          // The server rejected the change, so the next configuration retries it.
          await _metadata.delete(pushedKey);
          return;
        }
        revision = result.revision;
      }
    } finally {
      _running = false;
    }
  }
}
