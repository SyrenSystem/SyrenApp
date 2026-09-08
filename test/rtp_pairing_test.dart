import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:final_project/ui/laptop_audio_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const receivers = [
  SnapClientInfo(id: 'livingroom', name: 'livingroom'),
  SnapClientInfo(id: 'kitchen', name: 'kitchen'),
];

ProcessResult response(Map<String, dynamic> fields) =>
    ProcessResult(1, 0, jsonEncode({'version': 1, ...fields}), '');

Future<void> openPairing(WidgetTester tester, LocalAudioService service) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ReceiverConnectionDialog(service: service, receivers: receivers),
    ),
  );
  await tester.pumpAndSettle();
}

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  testWidgets('discovery fills editable fields without pairing or starting', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        if (arguments.first != 'rtp') {
          return ProcessResult(1, 0, 'disabled', '');
        }
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request);
        if (request['action'] == 'pair-discover') {
          return response({'host': 'livingroom.local', 'user': 'listener'});
        }
        return response({
          'fingerprint': 'SHA256:example',
          'challenge': 'proof',
        });
      },
    );
    service.rtp = const RtpStatus({
      'preferences': {'opt_in': true},
    });
    await openPairing(tester, service);
    expect(
      tester.widget<TextField>(field('SSH host')).controller!.text,
      'livingroom.local',
    );
    expect(
      tester.widget<TextField>(field('SSH user')).controller!.text,
      'listener',
    );
    expect(requests.map((request) => request['action']), ['pair-discover']);
    await tester.enterText(field('SSH user'), 'receiver_user');
    await tester.tap(find.text('Show host fingerprint'));
    await tester.pumpAndSettle();
    expect(requests.last['user'], 'receiver_user');
    expect(requests.last['host'], 'livingroom.local');
    expect(requests.last['port'], 22);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Pin verified key'),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty login has an inline error before any SSH probe', (
    tester,
  ) async {
    final requests = <String>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        if (arguments.first != 'rtp') {
          return ProcessResult(1, 0, 'disabled', '');
        }
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request['action'] as String);
        return response({'host': 'livingroom.local', 'user': 'listener'});
      },
    );
    service.rtp = const RtpStatus({
      'preferences': {'opt_in': true},
    });
    await openPairing(tester, service);
    await tester.enterText(field('SSH user'), '');
    await tester.tap(find.text('Show host fingerprint'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter the login name used on the receiver.'),
      findsOneWidget,
    );
    expect(find.textContaining('Bad state'), findsNothing);
    expect(requests, ['pair-discover']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('re-pair selects the saved receiver instead of the first one', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        if (arguments.first != 'rtp') {
          return ProcessResult(1, 0, 'disabled', '');
        }
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        requests.add(request);
        return response({
          'host': 'saved.example',
          'user': 'remote',
          'port': 2222,
        });
      },
    );
    service.rtp = const RtpStatus({
      'preferences': {
        'opt_in': true,
        'pairing': {'snapclient_id': 'kitchen', 'name': 'Kitchen'},
      },
    });
    await openPairing(tester, service);
    expect(requests.single['snapclient_id'], 'kitchen');
    expect(
      tester.widget<TextField>(field('SSH host')).controller!.text,
      'saved.example',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late discovery cannot overwrite another selected receiver', (
    tester,
  ) async {
    final delayed = Completer<ProcessResult>();
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async {
        if (arguments.first != 'rtp') {
          return ProcessResult(1, 0, 'disabled', '');
        }
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        if (request['snapclient_id'] == 'livingroom') return delayed.future;
        return response({'host': 'kitchen.local', 'user': 'cook'});
      },
    );
    service.rtp = const RtpStatus({
      'preferences': {'opt_in': true},
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ReceiverConnectionDialog(service: service, receivers: receivers),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('livingroom (livingroom)'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('kitchen (kitchen)').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field('SSH host')).controller!.text,
      'kitchen.local',
    );
    delayed.complete(
      response({'host': 'livingroom.local', 'user': 'listener'}),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field('SSH host')).controller!.text,
      'kitchen.local',
    );
    expect(
      tester.widget<TextField>(field('SSH user')).controller!.text,
      'cook',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
