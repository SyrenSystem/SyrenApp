import 'dart:async';

import 'package:final_project/models/distance_item.dart';
import 'package:final_project/models/position_3d.dart';
import 'package:final_project/models/server_status.dart';
import 'package:final_project/models/speaker_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

final distanceItemsProvider =
    StateNotifierProvider<DistanceItemsNotifier, List<DistanceItem>>((ref) {
      return DistanceItemsNotifier(Hive.box<DistanceItem>('distance_items'));
    });

final userPositionProvider = StateProvider<Position3D?>((ref) => null);
final speakersProvider = StateProvider<Map<String, SpeakerData>>((ref) => {});
final speakersListProvider = Provider<List<SpeakerData>>(
  (ref) => List<SpeakerData>.unmodifiable(ref.watch(speakersProvider).values),
);
final serverOnlineProvider = StateProvider<bool>((ref) => false);
final selectedNavIndexProvider = StateProvider<int>((ref) => 0);

final desiredSpeakerConnectionsProvider =
    StateNotifierProvider<DesiredSpeakerConnectionsNotifier, Map<String, bool>>(
      (ref) {
        return DesiredSpeakerConnectionsNotifier(
          Hive.box<bool>('speaker_connections'),
          Hive.box<String>('syren_metadata'),
        );
      },
    );

class DistanceItemsNotifier extends StateNotifier<List<DistanceItem>> {
  DistanceItemsNotifier(this._box) : super(_activeItems(_box));

  final Box<DistanceItem> _box;

  static List<DistanceItem> _activeItems(Box<DistanceItem> box) =>
      box.values.where((item) => item.active).toList();

  DistanceItem? getById(String id) => _box.get(id);

  void add(DistanceItem item) {
    if (_box.containsKey(item.id)) {
      updateDistance(item.id, item.distance);
      return;
    }
    unawaited(_box.put(item.id, item));
    _refreshFromBox();
  }

  void setInactive(DistanceItem item) {
    item.active = false;
    _refreshFromBox();
  }

  void updateDistance(String id, double distance) {
    final item = _box.get(id);
    if (item == null) {
      return;
    }
    item
      ..active = true
      ..distance = distance;
    _refreshFromBox();
  }

  void updateVolume(String id, double volume) {
    final item = _box.get(id);
    if (item == null) {
      return;
    }
    item.volume = volume;
    _refreshFromBox();
  }

  Future<void> commitVolume(String id, double volume) async {
    final item = _box.get(id);
    if (item == null) {
      return;
    }
    item.volume = volume;
    await item.save();
    _refreshFromBox();
  }

  Future<void> commitLabel(String id, String label) async {
    final item = _box.get(id);
    if (item == null) {
      return;
    }
    item.label = label;
    await item.save();
    _refreshFromBox();
  }

  void _refreshFromBox() {
    state = _activeItems(_box);
  }
}

class DesiredSpeakerConnectionsNotifier
    extends StateNotifier<Map<String, bool>> {
  DesiredSpeakerConnectionsNotifier(this._connections, this._metadata)
    : super(Map<String, bool>.unmodifiable(_connections.toMap()));

  static const _stateIdKey = 'server_state_id';
  final Box<bool> _connections;
  final Box<String> _metadata;

  String? get stateId => _metadata.get(_stateIdKey);

  Future<void> setDesired(String id, bool connected) async {
    await _connections.put(id.toLowerCase(), connected);
    _refresh();
  }

  Future<void> acknowledgeRemoval(String id) async {
    final normalizedId = id.toLowerCase();
    if (_connections.get(normalizedId) == false) {
      await _connections.delete(normalizedId);
      _refresh();
    }
  }

  Future<Map<String, bool>> reconcileStatus(ServerStatus status) async {
    final previousStateId = stateId;
    if (previousStateId == null || previousStateId != status.stateId) {
      await _connections.clear();
      await _connections.putAll({
        for (final id in status.connectedSpeakerIds) id: true,
      });
      await _metadata.put(_stateIdKey, status.stateId);
    } else {
      for (final id in status.connectedSpeakerIds) {
        if (!_connections.containsKey(id)) {
          await _connections.put(id, true);
        }
      }
    }
    _refresh();
    return state;
  }

  void _refresh() {
    state = Map<String, bool>.unmodifiable(_connections.toMap());
  }
}
