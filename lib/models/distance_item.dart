import 'package:hive_flutter/hive_flutter.dart';
part 'distance_item.g.dart';

@HiveType(typeId: 0)
class DistanceItem extends HiveObject{
  @HiveField(0)
  final String id;
  double distance;
  @HiveField(1)
  String label;
  @HiveField(2)
  double volume;
  bool active;

  DistanceItem({required this.id, this.distance = -1, this.active = false, this.volume = 100, this.label = "unknown" });
}
