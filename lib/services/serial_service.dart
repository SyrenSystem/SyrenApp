import 'dart:convert';
import 'package:final_project/serial/serial_base.dart';

class SerialService {
  SerialConnection? _serialConnection;
  Function(String id, double distance)? onDistanceReceived;

  bool get isConnected => _serialConnection?.connected ?? false;

  void initialize() {
    _serialConnection = SerialConnection.create((String message) {
      try {
        Map<String, dynamic> distanceData = jsonDecode(message);
        String id = distanceData["id"];
        double distance = (distanceData["distance"] as num).toDouble();

        onDistanceReceived?.call(id, distance);
      } catch (e) {
        print('Error processing distance data: $e');
      }
    });
  }

  Future<List<dynamic>> getAvailableDevices() async {
    if (_serialConnection == null) {
      initialize();
    }
    return await _serialConnection!.getAvailableDevices();
  }

  Future<void> connect(dynamic device) async {
    if (_serialConnection == null) {
      initialize();
    }
    await _serialConnection!.connect(device);
  }

  void disconnect() {
    _serialConnection?.disconnect();
  }

  void dispose() {
    disconnect();
  }
}
