class SystemConfiguration {
  const SystemConfiguration({
    required this.stateId,
    required this.revision,
    required this.speakers,
    required this.groups,
    required this.sources,
  });

  final String stateId;
  final int revision;
  final List<ConfiguredSpeaker> speakers;
  final List<PlaybackGroup> groups;
  final List<AudioSource> sources;

  factory SystemConfiguration.fromJson(Map<String, dynamic> json) {
    return SystemConfiguration(
      stateId: json['stateId'] as String,
      revision: (json['revision'] as num).toInt(),
      speakers: _maps(
        json['speakers'],
      ).map(ConfiguredSpeaker.fromJson).toList(growable: false),
      groups: _maps(
        json['groups'],
      ).map(PlaybackGroup.fromJson).toList(growable: false),
      sources: _maps(
        json['sources'],
      ).map(AudioSource.fromJson).toList(growable: false),
    );
  }

  ConfiguredSpeaker? speakerForSensor(String sensorId) {
    final normalizedId = sensorId.toLowerCase();
    return speakers
        .where((speaker) => speaker.sensorId?.toLowerCase() == normalizedId)
        .firstOrNull;
  }

  bool isSpeakerGrouped(String speakerId) =>
      groups.any((group) => group.speakerIds.contains(speakerId));

  static Iterable<Map<String, dynamic>> _maps(Object? value) sync* {
    if (value is! List) {
      throw const FormatException('Expected a list');
    }
    for (final entry in value) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Expected an object');
      }
      yield entry;
    }
  }
}

class ConfiguredSpeaker {
  const ConfiguredSpeaker({
    required this.id,
    required this.name,
    required this.snapClientId,
    required this.sensorId,
    required this.fullVolumeDistance,
    required this.muteDistance,
    required this.level,
    required this.calibrated,
  });

  final String id;
  final String name;
  final String snapClientId;
  final String? sensorId;
  final double fullVolumeDistance;
  final double muteDistance;
  final double level;
  final bool calibrated;

  factory ConfiguredSpeaker.fromJson(Map<String, dynamic> json) {
    return ConfiguredSpeaker(
      id: json['id'] as String,
      name: json['name'] as String,
      snapClientId: json['snapClientId'] as String,
      sensorId: json['sensorId'] as String?,
      fullVolumeDistance: (json['fullVolumeDistance'] as num).toDouble(),
      muteDistance: (json['muteDistance'] as num).toDouble(),
      level: (json['level'] as num).toDouble(),
      calibrated: json['calibrated'] as bool,
    );
  }
}

class PlaybackGroup {
  const PlaybackGroup({
    required this.id,
    required this.name,
    required this.speakerIds,
    required this.sourcePriority,
    required this.volumeMode,
    required this.masterVolume,
    required this.muted,
  });

  final String id;
  final String name;
  final List<String> speakerIds;
  final List<String> sourcePriority;
  final String volumeMode;
  final double masterVolume;
  final bool muted;

  bool get automatic => volumeMode == 'automatic';

  factory PlaybackGroup.fromJson(Map<String, dynamic> json) {
    return PlaybackGroup(
      id: json['id'] as String,
      name: json['name'] as String,
      speakerIds: (json['speakerIds'] as List).cast<String>(),
      sourcePriority: (json['sourcePriority'] as List).cast<String>(),
      volumeMode: json['volumeMode'] as String,
      masterVolume: (json['masterVolume'] as num).toDouble(),
      muted: json['muted'] as bool,
    );
  }
}

class AudioSource {
  const AudioSource({required this.id, required this.name});

  final String id;
  final String name;

  factory AudioSource.fromJson(Map<String, dynamic> json) {
    return AudioSource(id: json['id'] as String, name: json['name'] as String);
  }
}

class SystemRuntime {
  const SystemRuntime({
    required this.onlineSnapClients,
    required this.sources,
    this.snapserverOnline = true,
  });

  final List<SnapClientInfo> onlineSnapClients;
  final List<AudioSourceStatus> sources;
  final bool snapserverOnline;

  factory SystemRuntime.fromJson(Map<String, dynamic> json) {
    return SystemRuntime(
      onlineSnapClients: (json['onlineSnapClients'] as List)
          .cast<Map<String, dynamic>>()
          .map(SnapClientInfo.fromJson)
          .toList(growable: false),
      sources: (json['sources'] as List)
          .cast<Map<String, dynamic>>()
          .map(AudioSourceStatus.fromJson)
          .toList(growable: false),
      snapserverOnline: json['snapserverOnline'] as bool? ?? true,
    );
  }
}

class SnapClientInfo {
  const SnapClientInfo({required this.id, required this.name});

  final String id;
  final String name;

  factory SnapClientInfo.fromJson(Map<String, dynamic> json) {
    return SnapClientInfo(
      id: json['id'] as String,
      name: json['name'] as String,
    );
  }
}

class AudioSourceStatus {
  const AudioSourceStatus({required this.id, required this.active});

  final String id;
  final bool active;

  factory AudioSourceStatus.fromJson(Map<String, dynamic> json) {
    return AudioSourceStatus(
      id: json['id'] as String,
      active: json['active'] as bool,
    );
  }
}

class CommandResult {
  const CommandResult({
    required this.requestId,
    required this.success,
    required this.revision,
    required this.error,
  });

  final String requestId;
  final bool success;
  final int revision;
  final String? error;

  factory CommandResult.fromJson(Map<String, dynamic> json) {
    return CommandResult(
      requestId: json['requestId'] as String,
      success: json['success'] as bool,
      revision: (json['revision'] as num).toInt(),
      error: json['error'] as String?,
    );
  }
}
