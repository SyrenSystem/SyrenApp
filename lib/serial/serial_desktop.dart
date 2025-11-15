import 'package:libserialport/libserialport.dart';
import 'package:usb_serial/usb_serial.dart';
import 'serial_base.dart';
import 'dart:io';

class SerialDesktopConnection extends SerialConnection {
  late SerialPort _port;
  bool _connected = false;

  SerialDesktopConnection (final Function(String meassage) onMessage):
        super(onMessage){
}

  @override
  bool get connected => _connected;

  @override
  Future<bool> connect(String portName, [int portNumber = 115200]) {
    _port = SerialPort(portName);
    if (!_port.openRead()) {
      print("failed to open port to serial.");
      return Future.value(false);
    }

    final config = SerialPortConfig();
    config.baudRate = portNumber;
    config.bits = 8;
    config.stopBits = 1;
    config.parity = 0;
    _port.config = config;

    final reader = SerialPortReader(_port);
    reader.stream.listen((data) {
        dataReceived(data);
    });
    _connected = true;
    return Future.value(true);
}

  @override
  Future<void> disconnect() {
    if (_connected) {
      _port.close();
      _connected = false;
    }
    return Future.value();
  }

  @override
  Future<List<String>> getAvailableDevices() {
    final ports = SerialPort.availablePorts;
    return Future.value(ports);
  }
}