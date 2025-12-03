import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/models/distance_item.dart';
import 'package:final_project/models/volume_item.dart';
import 'package:final_project/models/position_3d.dart';
import 'package:final_project/models/speaker_data.dart';

// State providers
final distanceItemsProvider = StateNotifierProvider<DistanceItemsNotifier, List<DistanceItem>>((ref) {
  return DistanceItemsNotifier();
});

final volumeItemsProvider = StateNotifierProvider<VolumeItemsNotifier, List<VolumeItem>>((ref) {
  return VolumeItemsNotifier();
});

final userPositionProvider = StateProvider<Position3D?>((ref) => null);

final speakersProvider = StateProvider<Map<String, SpeakerData>>((ref) => {});

final selectedNavIndexProvider = StateProvider<int>((ref) => 0);

// State Notifiers
class DistanceItemsNotifier extends StateNotifier<List<DistanceItem>> {
  DistanceItemsNotifier() : super([]);

  void add(DistanceItem item) {
    state = [...state, item];
  }

  void remove(DistanceItem item) {
    state = state.where((i) => i.id != item.id).toList();
  }

  void updateDistance(String id, double distance) {
    final index = state.indexWhere((item) => item.id == id);
    if (index != -1) {
      state[index].distance = distance;
      state = [...state]; // Trigger rebuild
    }
  }

  void clear() {
    state = [];
  }
}

class VolumeItemsNotifier extends StateNotifier<List<VolumeItem>> {
  VolumeItemsNotifier() : super([]);

  void add(VolumeItem item) {
    // only add non-existing elements
    if (!state.any((volumeItem) => volumeItem.id == item.id)) {
      state = [...state, item];
    }
  }

  void updateVolume(String id, int volume) {
    final index = state.indexWhere((item) => item.id == id);
    if (index != -1) {
      state[index].volume = volume;
      state = [...state]; // Trigger rebuild
    }
  }

  void clear() {
    state = [];
  }
}
