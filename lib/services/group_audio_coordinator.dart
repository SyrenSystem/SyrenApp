import 'dart:async';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/services/local_audio_service.dart';

class GroupAudioCoordinator {
  GroupAudioCoordinator({
    required this.audio,
    required this.configuration,
    required this.runtime,
    required this.online,
    Future<bool> Function()? desktopActive,
  }) : desktopActive = desktopActive ?? audio.desktopAudioActive;

  final LocalAudioService audio;
  final SystemConfiguration? Function() configuration;
  final SystemRuntime? Function() runtime;
  final bool Function() online;
  final Future<bool> Function() desktopActive;
  Timer? _timer;
  Future<void>? _refreshing;
  bool _disposed = false;
  bool _refreshAgain = false;

  void start() {
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(refresh()),
    );
    unawaited(refresh());
  }

  Future<void> refresh() {
    _refreshAgain = true;
    return _refreshing ??= _refreshUntilCurrent().whenComplete(
      () => _refreshing = null,
    );
  }

  Future<void> _refreshUntilCurrent() async {
    while (_refreshAgain && !_disposed) {
      _refreshAgain = false;
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    if (_disposed || !audio.available || !online()) return;
    try {
      final active = await desktopActive();
      if (_disposed || !audio.available || !online()) return;
      final currentConfiguration = configuration();
      final currentRuntime = runtime();
      if (currentConfiguration == null ||
          currentRuntime == null ||
          !currentRuntime.snapserverOnline) {
        return;
      }
      await audio.followGroupPriority(
        configuration: currentConfiguration,
        runtime: currentRuntime,
        desktopActive: active,
      );
    } catch (error) {
      if (!_disposed) audio.reportError(error.toString());
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
