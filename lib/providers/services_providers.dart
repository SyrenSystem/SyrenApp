import 'dart:async';

import 'package:final_project/models/position_3d.dart';
import 'package:final_project/models/speaker_data.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/settings_provider.dart';
import 'package:final_project/services/mqtt_service.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:final_project/services/serial_service.dart';
import 'package:final_project/services/speaker_name_migration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

final mqttServiceProvider = Provider<MqttService>((ref) {
  final service = MqttService();
  ref.onDispose(() => unawaited(service.disconnect()));
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
  mqttService.onUserPositionCleared = () {
    ref.read(userPositionProvider.notifier).state = null;
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
  mqttService.onSpeakerRemoved = (speakerId) {
    final speakers = ref.read(speakersProvider.notifier);
    speakers.state = Map<String, SpeakerData>.of(speakers.state)
      ..remove(speakerId);
    if (speakers.state.length < 3) {
      ref.read(userPositionProvider.notifier).state = null;
    }
    unawaited(
      ref
          .read(desiredSpeakerConnectionsProvider.notifier)
          .acknowledgeRemoval(speakerId),
    );
  };
  mqttService.onServerStatus = (status) {
    ref.read(serverOnlineProvider.notifier).state = status.online;
    if (!status.online) {
      return;
    }
    unawaited(() async {
      final desired = await ref
          .read(desiredSpeakerConnectionsProvider.notifier)
          .reconcileStatus(status);
      for (final entry in desired.entries) {
        final listed = status.connectedSpeakerIds.contains(entry.key);
        if (entry.value && !listed) {
          mqttService.sendConnect(entry.key);
        } else if (!entry.value && listed) {
          mqttService.sendDisconnect(entry.key);
        }
      }
    }());
  };
  mqttService.onConfiguration = (configuration) {
    ref.read(systemConfigurationProvider.notifier).state = configuration;
    unawaited(ref.read(speakerNameMigrationProvider).run(configuration));
  };
  mqttService.onRuntime = (runtime) {
    ref.read(systemRuntimeProvider.notifier).state = runtime;
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
  ref.onDispose(service.dispose);
  return service;
});

final localAudioServiceProvider = Provider<LocalAudioService>((ref) {
  return LocalAudioService();
});

final localAudioEnabledProvider = FutureProvider<bool?>((ref) {
  return ref.watch(localAudioServiceProvider).status();
});

final speakerNameMigrationProvider = Provider<SpeakerNameMigration>((ref) {
  return SpeakerNameMigration(
    ref.read(distanceItemsProvider.notifier),
    Hive.box<String>('syren_metadata'),
    ref.read(mqttServiceProvider),
  );
});
