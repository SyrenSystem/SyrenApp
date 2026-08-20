import 'position_3d.dart';

class SpeakerData {
  final String id;
  final Position3D position;

  const SpeakerData({required this.id, required this.position});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpeakerData && other.id == id && other.position == position;

  @override
  int get hashCode => Object.hash(id, position);
}
