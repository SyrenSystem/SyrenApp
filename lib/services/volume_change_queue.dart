import 'dart:async';

import 'package:final_project/models/system_configuration.dart';

typedef VolumeSave = Future<CommandResult?> Function(SystemConfiguration);

class VolumeChangeSuperseded implements Exception {
  const VolumeChangeSuperseded();
}

class VolumeChangeQueue {
  VolumeChangeQueue(this._configuration);

  SystemConfiguration? _configuration;
  final Map<String, _VolumeChange> _pending = {};
  bool _running = false;
  bool _disposed = false;
  Completer<void>? _configurationChanged;
  Timer? _configurationDeadline;

  void updateConfiguration(SystemConfiguration? configuration) {
    _configuration = configuration;
    _configurationChanged?.complete();
    _configurationChanged = null;
  }

  Future<CommandResult?> enqueue(String key, VolumeSave save) {
    final configuration = _configuration;
    if (_disposed || configuration == null) return Future.value(null);
    final completion = Completer<CommandResult?>();
    final pending = _pending[key];
    if (pending != null && pending.stateId == configuration.stateId) {
      pending.save = save;
      pending.completions.add(completion);
    } else {
      pending?.complete(null);
      _pending[key] = _VolumeChange(configuration.stateId, save, completion);
    }
    if (!_running) unawaited(_drain());
    return completion.future;
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_pending.isNotEmpty && !_disposed) {
        final change = _pending.remove(_pending.keys.first)!;
        final configuration = _configuration;
        if (configuration == null || configuration.stateId != change.stateId) {
          change.complete(null);
          continue;
        }
        try {
          var result = await change.save(configuration);
          if (result?.success == true &&
              !await _waitForConfiguration(change.stateId, result!.revision)) {
            result = null;
          }
          change.complete(result);
          if (result?.success != true) {
            // Do not replay queued gestures after an uncertain or rejected save.
            _cancelPending();
          }
        } on VolumeChangeSuperseded {
          change.complete(null);
        } catch (error, stackTrace) {
          for (final completion in change.completions) {
            completion.completeError(error, stackTrace);
          }
          _cancelPending();
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<bool> _waitForConfiguration(String stateId, int revision) async {
    var expired = false;
    _configurationDeadline = Timer(const Duration(seconds: 8), () {
      expired = true;
      _configurationChanged?.complete();
      _configurationChanged = null;
    });
    try {
      while (!_disposed && !expired) {
        final configuration = _configuration;
        if (configuration == null || configuration.stateId != stateId) {
          return false;
        }
        if (configuration.revision >= revision) return true;
        _configurationChanged = Completer<void>();
        await _configurationChanged!.future;
      }
      return false;
    } finally {
      _configurationDeadline?.cancel();
      _configurationDeadline = null;
    }
  }

  void _cancelPending() {
    for (final change in _pending.values) {
      change.complete(null);
    }
    _pending.clear();
  }

  void dispose() {
    _disposed = true;
    _cancelPending();
    _configurationDeadline?.cancel();
    _configurationChanged?.complete();
    _configurationChanged = null;
  }
}

class _VolumeChange {
  _VolumeChange(this.stateId, this.save, Completer<CommandResult?> completion)
    : completions = [completion];

  final String stateId;
  VolumeSave save;
  final List<Completer<CommandResult?>> completions;

  void complete(CommandResult? result) {
    for (final completion in completions) {
      completion.complete(result);
    }
  }
}
