import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/models/position_3d.dart';
import 'package:final_project/models/speaker_data.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/settings_provider.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/serial_service.dart';

// Service providers
final mqttServiceProvider = Provider<MqttService>((ref) {
  final service = MqttService();
  ref.onDispose(() {
    unawaited(service.disconnect());
  });
  return service;
});

final mqttConnectionRetryDelayProvider = Provider<Duration>((ref) {
  return const Duration(seconds: 5);
});

final mqttConnectionProvider = FutureProvider<bool>((ref) async {
  final settings = ref.watch(settingsProvider);
  final mqttService = ref.watch(mqttServiceProvider);
  final retryDelay = ref.watch(mqttConnectionRetryDelayProvider);
  Timer? retryTimer;
  bool disposed = false;

  ref.onDispose(() {
    disposed = true;
    retryTimer?.cancel();
  });

  mqttService.onUserPositionReceived = (positionData) {
    ref.read(userPositionProvider.notifier).state = Position3D.fromJson(
      positionData,
    );
  };

  mqttService.onSpeakerPositionReceived = (speakerId, positionData) {
    final speakers = ref.read(speakersProvider.notifier);
    speakers.state = {
      ...speakers.state,
      speakerId: SpeakerData(
        id: speakerId,
        position: Position3D.fromJson(positionData),
      ),
    };
  };

  if (settings.ip.isEmpty || settings.port <= 0) {
    return false;
  }

  final connected = await mqttService.connect(settings.ip, settings.port);
  if (!connected && !disposed) {
    retryTimer = Timer(retryDelay, () {
      if (!disposed) {
        ref.invalidateSelf();
      }
    });
  }

  return connected;
});

final serialServiceProvider = Provider<SerialService>((ref) {
  final service = SerialService();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
