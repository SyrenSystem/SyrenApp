import 'dart:async';

import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/services/mqtt_service.dart';

class VolumeCommitCoordinator {
  VolumeCommitCoordinator(this._distanceItems, this._mqttService);

  static const debounceDuration = Duration(milliseconds: 200);

  final DistanceItemsNotifier _distanceItems;
  final MqttService _mqttService;
  final Map<String, Timer> _timers = {};
  final Map<String, double> _pendingVolumes = {};

  void update(String id, double volume) {
    _distanceItems.updateVolume(id, volume);
    _pendingVolumes[id] = volume;
    _timers.remove(id)?.cancel();
    _timers[id] = Timer(debounceDuration, () => unawaited(flush(id)));
  }

  Future<void> flush(String id) async {
    _timers.remove(id)?.cancel();
    final volume = _pendingVolumes.remove(id);
    if (volume == null) {
      return;
    }
    await _distanceItems.commitVolume(id, volume);
    _mqttService.sendVolumeUpdate(id, volume);
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final id in _pendingVolumes.keys.toList()) {
      unawaited(flush(id));
    }
  }
}
