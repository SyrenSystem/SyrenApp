import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/models/distance_item.dart';
import 'package:final_project/models/position_3d.dart';
import 'package:final_project/models/speaker_data.dart';
import 'package:hive/hive.dart';

// State providers
final distanceItemsProvider = StateNotifierProvider<DistanceItemsNotifier, List<DistanceItem>>((ref) {
  final box = Hive.box<DistanceItem>("distance_items");
  return DistanceItemsNotifier(box);
});

final userPositionProvider = StateProvider<Position3D?>((ref) => null);

final speakersProvider = StateProvider<Map<String, SpeakerData>>((ref) => {});

final selectedNavIndexProvider = StateProvider<int>((ref) => 0);

// State Notifiers
class DistanceItemsNotifier extends StateNotifier<List<DistanceItem>> {
  final Box<DistanceItem> _box;

  DistanceItemsNotifier(this._box) : super(_box.values.where((it) => it.active).toList());

  void add(DistanceItem item) {
    if (_box.values.any((distanceItem) => item.id == distanceItem.id)) {
      updateDistance(item.id, item.distance);
    }
    else
      {
        _box.put(item.id, item);
        state = _box.values.where((it) => it.active).toList();
      }
  }

  void setInactive(DistanceItem item) {
    item.active = false;
    state = _box.values.where((it) => it.active).toList();
  }
  
  void remove(DistanceItem item) {
    _box.delete(item.id);
    state = _box.values.where((it) => it.active).toList();
  }

  void updateDistance(String id, double distance) {
    final item = _box.get(id);
    if (item != null) {
      if (!item.active) {
          item.active = true;
        }
      item.distance = distance;
      state = _box.values.where((it) => it.active).toList();
    }
  }

  void clear() {
    _box.clear();
    state = [];
  }

  void updateVolume(String id, double volume) {
    final index = state.indexWhere((item) => item.id == id);
    if (index != -1) {
      state[index].volume = volume;
      state = [...state]; // Trigger rebuild
    }
  }
}