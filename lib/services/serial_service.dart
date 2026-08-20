import 'dart:async';
import 'dart:convert';

import 'package:final_project/serial/serial_base.dart';
import 'package:flutter/foundation.dart';

class SerialService {
  SerialConnection? _serialConnection;
  void Function(String id, double distance)? onDistanceReceived;

  bool get isConnected => _serialConnection?.connected ?? false;

  void initialize() {
    _serialConnection = SerialConnection.create(handleLine);
  }

  @visibleForTesting
  void handleLine(String message) {
    dynamic decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    final id = decoded['id'];
    final rawDistance = decoded['distance'];
    if (id is! String || id.trim().isEmpty || rawDistance is! num) {
      return;
    }
    final distance = rawDistance.toDouble();
    if (!distance.isFinite || distance < 0) {
      return;
    }
    try {
      onDistanceReceived?.call(id.toLowerCase(), distance);
    } catch (error) {
      debugPrint('Distance callback failed: $error');
    }
  }

  Future<List<String>> getAvailableDevices() async {
    _serialConnection ??= SerialConnection.create(handleLine);
    return _serialConnection!.getAvailableDevices();
  }

  Future<bool> connect(String device) async {
    _serialConnection ??= SerialConnection.create(handleLine);
    return _serialConnection!.connect(device);
  }

  Future<void> disconnect() async {
    await _serialConnection?.disconnect();
  }

  void dispose() {
    unawaited(disconnect());
  }
}
