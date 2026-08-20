import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:usb_serial/usb_serial.dart';

import 'serial_base.dart';

class SerialAndroidConnection extends SerialConnection {
  UsbPort? _port;
  StreamSubscription<Uint8List>? _subscription;
  bool _connected = false;

  SerialAndroidConnection(super.onMessage);

  @override
  bool get connected => _connected;

  @override
  Future<bool> connect(String portName, [int baudRate = 115200]) async {
    await disconnect();
    final devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      return false;
    }

    UsbDevice device = devices.first;
    for (final candidate in devices) {
      if (candidate.deviceName == portName) {
        device = candidate;
        break;
      }
    }
    if (device.deviceName != portName) {
      debugPrint(
        'USB device $portName was not found, using ${device.deviceName}',
      );
    }

    final port = await device.create();
    if (port == null || !await port.open()) {
      debugPrint('Failed to open USB serial device ${device.deviceName}');
      return false;
    }
    _port = port;
    try {
      await port.setDTR(true);
      await port.setRTS(true);
      await port.setPortParameters(
        baudRate,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );
      _subscription = port.inputStream?.listen(
        dataReceived,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('USB serial error: $error');
          unawaited(disconnect());
        },
      );
      _connected = true;
      return true;
    } catch (error) {
      debugPrint('Failed to configure USB serial device $portName: $error');
      await disconnect();
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _subscription?.cancel();
    _subscription = null;
    final port = _port;
    _port = null;
    if (port != null) {
      await port.close();
    }
    resetBuffer();
  }

  @override
  Future<List<String>> getAvailableDevices() async {
    final devices = await UsbSerial.listDevices();
    return devices.map((device) => device.deviceName).toList();
  }
}
