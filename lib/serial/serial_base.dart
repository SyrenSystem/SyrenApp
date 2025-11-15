import 'dart:convert';
import 'dart:typed_data';

import 'package:final_project/serial/serial_android.dart';
import 'package:final_project/serial/serial_desktop.dart';
import 'package:libserialport/libserialport.dart';
import 'dart:io';

  abstract class SerialConnection {
    String _buffer = '';
    static SerialConnection create(onMessageReceivedCallback) {
      if (Platform.isAndroid)
      {
        return SerialAndroidConnection(onMessageReceivedCallback);
      }
      return SerialDesktopConnection(onMessageReceivedCallback);
    }

  Future<List<String>> getAvailableDevices();
  Future<bool> connect(String portName, [int port = 115200]);
  Future<void> disconnect();
  final Function(String meassage) onMessage;
  SerialConnection(this.onMessage);

  void dataReceived(Uint8List data)
  {
    String text = utf8.decode(data);
    _buffer += text;
    while (_buffer.contains('\r\n'))
      {
        final lineEnd = _buffer.indexOf('\n');
        final line = _buffer.substring(0, lineEnd).trim();
        _buffer = _buffer.substring(lineEnd + 1);
        onMessage(line);
      }
  }
}