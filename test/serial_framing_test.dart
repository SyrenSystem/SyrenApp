import 'dart:convert';
import 'dart:typed_data';

import 'package:final_project/serial/serial_base.dart';
import 'package:final_project/services/serial_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('frames LF and CRLF lines across chunks', () {
    final messages = <String>[];
    final connection = TestSerialConnection(messages.add);

    connection.addBytes(utf8.encode('first\r\nsec'));
    connection.addBytes(utf8.encode('ond\n'));

    expect(messages, ['first', 'second']);
  });

  test('decodes a multibyte character split across chunks', () {
    final messages = <String>[];
    final connection = TestSerialConnection(messages.add);
    final encoded = utf8.encode('afstand €\n');

    connection.addBytes(encoded.sublist(0, encoded.length - 2));
    connection.addBytes(encoded.sublist(encoded.length - 2));

    expect(messages, ['afstand €']);
  });

  test('malformed bytes do not stop later frames', () {
    final messages = <String>[];
    final connection = TestSerialConnection(messages.add);

    connection.addBytes([0xff, 0x0a, ...utf8.encode('valid\n')]);

    expect(messages, ['�', 'valid']);
  });

  test('oversized frames are discarded until the next newline', () {
    final messages = <String>[];
    final connection = TestSerialConnection(messages.add);

    connection.addBytes(
      List<int>.filled(SerialConnection.maximumFrameBytes + 1, 0x61),
    );
    connection.addBytes([0x0a, ...utf8.encode('valid\n')]);

    expect(messages, ['valid']);
  });

  test('reset drops an incomplete frame', () {
    final messages = <String>[];
    final connection = TestSerialConnection(messages.add);

    connection.addBytes(utf8.encode('discard'));
    connection.resetBuffer();
    connection.addBytes(utf8.encode('keep\n'));

    expect(messages, ['keep']);
  });

  test('serial service accepts valid distance objects only', () {
    final service = SerialService();
    final distances = <(String, double)>[];
    service.onDistanceReceived = (id, distance) {
      distances.add((id, distance));
    };

    service.handleLine('boot chatter');
    service.handleLine('{}');
    service.handleLine('{"id":"AA:BB","distance":-1}');
    service.handleLine('{"id":"AA:BB","distance":"12"}');
    service.handleLine('{"id":"AA:BB","distance":12.5}');

    expect(distances, [('aa:bb', 12.5)]);
  });

  test('serial callback failures do not escape the parser', () {
    final service = SerialService();
    service.onDistanceReceived = (id, distance) {
      throw StateError('callback failed');
    };

    expect(
      () => service.handleLine('{"id":"sensor","distance":1}'),
      returnsNormally,
    );
  });
}

class TestSerialConnection extends SerialConnection {
  TestSerialConnection(super.onMessage);

  @override
  bool get connected => true;

  void addBytes(List<int> bytes) {
    dataReceived(Uint8List.fromList(bytes));
  }

  @override
  Future<bool> connect(String portName, [int baudRate = 115200]) async => true;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<String>> getAvailableDevices() async => [];
}
