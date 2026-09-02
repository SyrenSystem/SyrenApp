import 'dart:io';

import 'package:final_project/services/local_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads enabled audio state', () async {
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) async =>
          ProcessResult(1, 0, 'enabled\n', ''),
    );

    expect(await service.status(), isTrue);
  });

  test('reports a missing control command as unavailable', () async {
    final service = LocalAudioService(
      available: true,
      runner: (executable, arguments) =>
          throw ProcessException(executable, arguments),
    );

    expect(await service.status(), isNull);
    expect(await service.setEnabled(true), isFalse);
  });

  test('falls back to the local bin control script', () async {
    const fallback = '/home/tester/.local/bin/syren-audio-control';
    final executables = <String>[];
    final service = LocalAudioService(
      available: true,
      fallbackExecutable: fallback,
      runner: (executable, arguments) async {
        executables.add(executable);
        if (executable == fallback) {
          return ProcessResult(1, 0, 'enabled\n', '');
        }
        throw ProcessException(executable, arguments);
      },
    );

    expect(await service.status(), isTrue);
    expect(executables, ['syren-audio-control', fallback]);
  });

  test('reports unavailable off linux', () async {
    var runnerCalls = 0;
    final service = LocalAudioService(
      available: false,
      runner: (executable, arguments) async {
        runnerCalls++;
        return ProcessResult(1, 0, 'enabled\n', '');
      },
    );

    expect(service.available, isFalse);
    expect(await service.status(), isNull);
    expect(await service.setEnabled(true), isFalse);
    expect(runnerCalls, 0);
  });
}
