import 'package:final_project/serial/serial_base.dart';
import 'package:usb_serial/usb_serial.dart';
import 'dart:typed_data';

class SerialAndroidConnection extends SerialConnection {
  UsbPort? _port;
  bool _connected = false;

  SerialAndroidConnection(final Function(String meassage) onMessage): super(onMessage) {
  }

  @override
  Future<bool> connect(String portName, [int port = 115200]) async {
    if (_connected && _port != null)
      {
        return true;
      }
      List<UsbDevice> devices = await UsbSerial.listDevices();
      print(devices);
        if (devices.length == 0) {
           return false;
        }
      _port = await devices[0].create();

      if (_port != null) {
        bool openResult = await _port!.open();
        if (!openResult) {
          print("Failed to open");
          return false;
        }

        await _port!.setDTR(true);
        await _port!.setRTS(true);

        _port!.setPortParameters(115200, UsbPort.DATABITS_8,
            UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

        _port!.inputStream!.listen((Uint8List data) {
          dataReceived(data);
        });
      }

    return true;
  }

  @override
  Future<void> disconnect() async {
    _port?.close();
    _connected = false;
  }

  @override
  Future<List<String>> getAvailableDevices() async {
    List<UsbDevice> devices = await UsbSerial.listDevices();
    List<String> deviceNames = devices.map((device) => device.deviceName ?? "Unknown device").toList();
    return deviceNames;
  }
}