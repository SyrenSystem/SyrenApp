String abbreviateId(String id) {
  if (id.length <= 12) {
    return id;
  }
  return '${id.substring(0, 6)}...${id.substring(id.length - 6)}';
}

String formatDistanceMillimeters(double distance) =>
    '${distance.toStringAsFixed(1)} mm';
