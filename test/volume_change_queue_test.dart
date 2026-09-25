import 'dart:async';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/services/volume_change_queue.dart';
import 'package:flutter_test/flutter_test.dart';

SystemConfiguration configuration(int revision, {String stateId = 'state'}) =>
    SystemConfiguration(
      stateId: stateId,
      revision: revision,
      speakers: const [],
      groups: const [],
      sources: const [],
    );

CommandResult result(int revision, {bool success = true}) => CommandResult(
  requestId: 'request',
  success: success,
  revision: revision,
  error: success ? null : 'Configuration changed; reload and try again',
);

void main() {
  for (final failure in [null, result(2, success: false)]) {
    test(
      'a failed save cancels queued volume changes: ${failure?.error}',
      () async {
        final queue = VolumeChangeQueue(configuration(1));
        addTearDown(queue.dispose);
        final response = Completer<CommandResult?>();
        final first = queue.enqueue('group', (_) => response.future);
        var laterCalled = false;
        final later = queue.enqueue('speaker', (_) async {
          laterCalled = true;
          return result(2);
        });
        response.complete(failure);
        expect(await first, failure);
        expect(await later, isNull);
        expect(laterCalled, isFalse);
      },
    );
  }

  test(
    'exceptions release the queue and cancel older pending gestures',
    () async {
      final queue = VolumeChangeQueue(configuration(1));
      addTearDown(queue.dispose);
      final response = Completer<CommandResult?>();
      final first = queue.enqueue('group', (_) => response.future);
      final failure = expectLater(first, throwsStateError);
      final later = queue.enqueue('speaker', (_) async => result(2));
      response.completeError(StateError('Audio connection changed'));
      await failure;
      expect(await later, isNull);
      queue.updateConfiguration(configuration(3));
      expect(
        await queue.enqueue(
          'group',
          (current) async => result(current.revision),
        ),
        isNotNull,
      );
    },
  );

  testWidgets(
    'a missing configuration acknowledgement times out without replay',
    (tester) async {
      final queue = VolumeChangeQueue(configuration(1));
      addTearDown(queue.dispose);
      final first = queue.enqueue('group', (_) async => result(2));
      var laterCalled = false;
      final later = queue.enqueue('group', (_) async {
        laterCalled = true;
        return result(3);
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      expect(await first, isNull);
      expect(await later, isNull);
      expect(laterCalled, isFalse);
    },
  );

  for (final dispose in [false, true]) {
    testWidgets(
      'pending volume is discarded on ${dispose ? 'disposal' : 'server replacement'}',
      (tester) async {
        final queue = VolumeChangeQueue(configuration(1));
        addTearDown(queue.dispose);
        final first = queue.enqueue('group', (_) async => result(2));
        var laterCalled = false;
        final later = queue.enqueue('speaker', (_) async {
          laterCalled = true;
          return result(3);
        });
        await tester.pump();
        if (dispose) {
          queue.dispose();
        } else {
          queue.updateConfiguration(configuration(9, stateId: 'replacement'));
        }
        await tester.pump();
        expect(await first, isNull);
        expect(await later, isNull);
        expect(laterCalled, isFalse);
      },
    );
  }
}
