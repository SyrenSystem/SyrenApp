import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:final_project/serial/serial_android.dart';
import 'package:final_project/serial/serial_desktop.dart';
import 'package:final_project/serial/serial_ios.dart';

typedef SerialMessageCallback = void Function(String message);

abstract class SerialConnection {
  static const int maximumFrameBytes = 64 * 1024;

  final SerialMessageCallback onMessage;
  final List<int> _buffer = <int>[];
  bool _discardingOversizedFrame = false;

  SerialConnection(this.onMessage);

  bool get connected;
  String? get unavailableReason => null;

  static SerialConnection create(SerialMessageCallback onMessage) {
    if (Platform.isAndroid) {
      return SerialAndroidConnection(onMessage);
    }
    if (Platform.isIOS) {
      return SerialIosConnection(onMessage);
    }
    return SerialDesktopConnection(onMessage);
  }

  Future<List<String>> getAvailableDevices();
  Future<bool> connect(String portName, [int baudRate = 115200]);
  Future<void> disconnect();

  void dataReceived(Uint8List data) {
    for (final byte in data) {
      if (_discardingOversizedFrame) {
        if (byte == 0x0a) {
          _discardingOversizedFrame = false;
        }
        continue;
      }

      if (byte == 0x0a) {
        final line = const Utf8Decoder(
          allowMalformed: true,
        ).convert(_buffer).trim();
        _buffer.clear();
        if (line.isNotEmpty) {
          onMessage(line);
        }
        continue;
      }

      _buffer.add(byte);
      if (_buffer.length > maximumFrameBytes) {
        _buffer.clear();
        _discardingOversizedFrame = true;
      }
    }
  }

  void resetBuffer() {
    _buffer.clear();
    _discardingOversizedFrame = false;
  }
}
