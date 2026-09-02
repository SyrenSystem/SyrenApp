import 'serial_base.dart';

class SerialIosConnection extends SerialConnection {
  SerialIosConnection(super.onMessage);

  static const String unsupportedMessage =
      'USB serial sensors are not supported on iOS. Use Android or a desktop computer to collect measurements.';

  @override
  bool get connected => false;

  @override
  String get unavailableReason => unsupportedMessage;

  @override
  Future<bool> connect(String portName, [int baudRate = 115200]) async => false;

  @override
  Future<void> disconnect() async {
    resetBuffer();
  }

  @override
  Future<List<String>> getAvailableDevices() async => const [];
}
