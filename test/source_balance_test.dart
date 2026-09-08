import 'dart:convert';
import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:final_project/ui/settings_page_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'laptop_playback_test.dart' as playback;

void main() {
  test('older groups use full source levels and saved balance loads', () {
    final json = <String, dynamic>{
      'id': 'group',
      'name': 'Group',
      'speakerIds': <String>[],
      'sourcePriority': ['spotify', 'laptop'],
      'volumeMode': 'manual',
      'masterVolume': 50,
      'muted': false,
    };
    expect(PlaybackGroup.fromJson(json).sourceLevel('spotify'), 100);
    json['sourceLevels'] = {'spotify': 40, 'laptop': 80};
    final group = PlaybackGroup.fromJson(json);
    expect(group.sourceLevel('spotify'), 40);
    expect(group.sourceLevel('laptop'), 80);
    expect(group.masterVolume, 50);
  });

  test('RTP confirms the source balance before unmuting', () async {
    var remote = playback.status('readyMuted');
    final service = LocalAudioService(
      available: true,
      runner: (_, arguments) async {
        final request = jsonDecode(arguments[1]) as Map<String, dynamic>;
        if (request['action'] == 'volume') {
          remote = playback.status(
            'readyMuted',
            percent: request['percent'] as int,
          );
        }
        if (request['action'] == 'unmute') {
          expect(remote['percent'], 20);
          remote = playback.status('playing', percent: 20);
        }
        return playback.response(remote);
      },
    );
    service.rtp = RtpStatus(remote);
    await service.enablePlayback(
      groupVolume: 50,
      speakerLevel: 80,
      sourceLevel: 50,
    );
    expect(service.rtp.percent, 20);
    expect(service.rtp.state, 'playing');
    service.dispose();
  });

  testWidgets('Settings shows version from installed bundle metadata', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (message) async {
        if (utf8.decode(message!.buffer.asUint8List()) == 'version.json') {
          return ByteData.sublistView(
            Uint8List.fromList(utf8.encode('{"version":"2.3.4"}')),
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        'flutter/assets',
        null,
      ),
    );
    rootBundle.evict('version.json');
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: SettingsPageWidget())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Version 2.3.4'), findsOneWidget);
  });
}
