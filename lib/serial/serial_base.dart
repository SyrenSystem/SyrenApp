import 'package:libserialport/libserialport.dart';

  abstract class SerialConnection {
  List<String> getAvailableDevices();
  bool connect(String deviceName, [int port = 115200]);
  void disconnect();
  final Function(String meassage) onMessage;
  SerialConnection(this.onMessage);
}