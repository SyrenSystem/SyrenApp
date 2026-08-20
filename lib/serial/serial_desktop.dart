import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:libserialport/libserialport.dart';

import 'serial_base.dart';

class SerialDesktopConnection extends SerialConnection {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _subscription;
  bool _connected = false;

  SerialDesktopConnection(super.onMessage);

  @override
  bool get connected => _connected;

  @override
  Future<bool> connect(String portName, [int baudRate = 115200]) async {
    await disconnect();
    final port = SerialPort(portName);
    _port = port;
    if (!port.openRead()) {
      debugPrint('Failed to open serial port $portName');
      port.dispose();
      _port = null;
      return false;
    }
    try {
      final config = SerialPortConfig()
        ..baudRate = baudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = 0;
      try {
        port.config = config;
      } finally {
        config.dispose();
      }

      final reader = SerialPortReader(port);
      _reader = reader;
      _subscription = reader.stream.listen(
        dataReceived,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('Serial port error: $error');
          unawaited(disconnect());
        },
      );
      _connected = true;
      return true;
    } catch (error) {
      debugPrint('Failed to configure serial port $portName: $error');
      await disconnect();
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _subscription?.cancel();
    _subscription = null;
    _reader?.close();
    _reader = null;
    final port = _port;
    _port = null;
    if (port != null) {
      if (port.isOpen) {
        port.close();
      }
      port.dispose();
    }
    resetBuffer();
  }

  @override
  Future<List<String>> getAvailableDevices() async => SerialPort.availablePorts;
}
