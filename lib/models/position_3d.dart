class Position3D {
  final double x;
  final double y;
  final double z;

  Position3D({required this.x, required this.y, required this.z});

  factory Position3D.fromJson(Map<String, dynamic> json) {
    return Position3D(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      z: (json['z'] as num).toDouble(),
    );
  }
}
