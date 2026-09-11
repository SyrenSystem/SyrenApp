import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:final_project/models/system_configuration.dart';

typedef AudioControlRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class LocalAudioService extends ChangeNotifier {
  LocalAudioService({
    AudioControlRunner? runner,
    bool? available,
    String? fallbackExecutable,
  }) : _runner = runner ?? _boundedRun,
       available = available ?? Platform.isLinux,
       _fallbackExecutable =
           fallbackExecutable ??
           '${Platform.environment['HOME']}/.local/bin/syren-audio-control';

  static const _executable = 'syren-audio-control';

  final AudioControlRunner _runner;
  final String _fallbackExecutable;
  final bool available;
  RtpStatus rtp = const RtpStatus({});
  String? rtpError;
  Timer? _heartbeat;
  Timer? _muteTimer;
  bool _polling = false;
  bool _disposed = false;
  int _muteRevision = 0;
  int _stateRevision = 0;
  int? _minimumMuteGeneration;
  String? _muteSession;
  String? muteFeedback;
  int _playbackIntent = 0;
  int _volumeIntent = 0;
  bool _startingPlayback = false;
  String? _pendingPlaybackSession;
  int? _pendingPlaybackVolume;
  bool _pendingPlaybackMuted = false;
  bool _applyingPlaybackVolume = false;
  Timer? _playbackDeadline;
  bool playbackRequested = false;
  bool _prioritySuspended = false;
  bool _priorityAllowsPlayback = true;
  bool _priorityChanging = false;
  bool _priorityGroupMuted = false;
  bool _standbyMuted = false;
  bool _resumePending = false;
  // The mute revision at the moment a failed heartbeat left the controller state unknown.
  int? _heartbeatDoubtRevision;
  bool _heartbeatFailed = false;
  bool? _configuredMuted;
  int? _configuredVolume;

  bool get waitingForPriority => playbackRequested && _prioritySuspended;

  // True while a recovered receiver waits for the coordinator to confirm volume and resume.
  bool get resumePending => playbackRequested && _resumePending;

  Future<void> followGroupPriority({
    required SystemConfiguration configuration,
    required SystemRuntime runtime,
    required bool desktopActive,
  }) async {
    final speaker = configuration.speakers
        .where(
          (speaker) => speaker.snapClientId == rtp.pairing?['snapclient_id'],
        )
        .firstOrNull;
    final group = configuration.groups
        .where((group) => group.speakerIds.contains(speaker?.id))
        .firstOrNull;
    final active = {
      for (final source in runtime.sources) source.id: source.active,
      'laptop': desktopActive,
    };
    final selected = group?.sourcePriority
        .where((source) => active[source] == true)
        .firstOrNull;
    // Keep laptop audio ready between sounds when no other source is active.
    _priorityAllowsPlayback =
        selected == 'laptop' ||
        (selected == null &&
            (group?.sourcePriority.contains('laptop') ?? false));
    _priorityGroupMuted = group?.muted ?? false;
    // Only changes made to the stored group count, so a local slider ramp is never undone by stale configuration.
    final configuredVolume = group != null && speaker != null
        ? _combinedLevel(
            group.masterVolume,
            speaker.level,
            group.sourceLevel('laptop'),
          )
        : null;
    final mutedChanged =
        _configuredMuted != null && group?.muted != _configuredMuted;
    final volumeChanged = configuredVolume != _configuredVolume;
    _configuredMuted = group?.muted;
    _configuredVolume = configuredVolume;
    if (!playbackRequested) return;
    if (enablingPlayback) {
      if (volumeChanged && configuredVolume != null) {
        _pendingPlaybackVolume = configuredVolume;
      }
      if (mutedChanged && group != null) _pendingPlaybackMuted = group.muted;
      return;
    }
    if (!_priorityAllowsPlayback) {
      if ((!_prioritySuspended || _standbyMuted != _priorityGroupMuted) &&
          ['playing', 'readyMuted'].contains(rtp.state)) {
        await standbyRtp(muted: _priorityGroupMuted);
      }
    } else if (speaker == null || group == null) {
      return;
    } else if ((_prioritySuspended || _resumePending) && canUnmute) {
      await enablePlayback(
        groupVolume: group.masterVolume,
        sourceLevel: group.sourceLevel('laptop'),
        speakerLevel: speaker.level,
        muted: group.muted,
      );
    } else if (mutedChanged) {
      if (group.muted && rtp.state == 'playing') {
        await muteRtp();
      } else if (!group.muted && canUnmute) {
        await enablePlayback(
          groupVolume: group.masterVolume,
          sourceLevel: group.sourceLevel('laptop'),
          speakerLevel: speaker.level,
        );
      }
    }
    if (_priorityAllowsPlayback &&
        volumeChanged &&
        configuredVolume != null &&
        configuredVolume != rtp.percent) {
      await setPlaybackVolume(configuredVolume);
    }
  }

  Future<bool> desktopAudioActive() async {
    final result = await _boundedRun('pactl', [
      '--format=json',
      'list',
      'sink-inputs',
    ], timeout: const Duration(seconds: 3));
    if (result.exitCode != 0) {
      throw StateError('Could not inspect laptop playback.');
    }
    final streams = jsonDecode(result.stdout as String) as List;
    return streams.cast<Map<String, dynamic>>().any(
      (stream) => stream['corked'] == false && stream['mute'] != true,
    );
  }

  bool get enablingPlayback =>
      _startingPlayback || _pendingPlaybackSession != null;

  Future<void> refreshRtp() => _update('status');

  Future<void> enablePlayback({
    required double groupVolume,
    required double speakerLevel,
    double sourceLevel = 100,
    bool muted = false,
  }) async {
    final volume = _combinedLevel(groupVolume, speakerLevel, sourceLevel);
    if (enablingPlayback) return;
    playbackRequested = true;
    _prioritySuspended = false;
    if (canUnmute) {
      final session = rtp.session;
      final generation = rtp.generation;
      final intent = _playbackIntent;
      // The flag stays set until the ramp confirms, so a superseded ramp is retried by the coordinator.
      _resumePending = true;
      rtpError = null;
      try {
        await setPlaybackVolume(volume);
        if (!_priorityAllowsPlayback) {
          await standbyRtp(muted: muted);
          return;
        }
        if (intent != _playbackIntent ||
            rtp.session != session ||
            rtp.generation != generation) {
          // A mute or recovery moved the receiver on, and its own handling decides whether to resume.
          return;
        }
        if (rtp.percent != volume || !canUnmute) return;
        _resumePending = false;
        if (muted || _priorityGroupMuted) {
          if (rtp.outputMuted != true) await muteRtp();
        } else {
          await unmuteRtp();
        }
      } catch (_) {
        // A failed ramp drops the intent so a recovery loop cannot keep retrying it.
        playbackRequested = false;
        rethrow;
      }
      return;
    }
    _resumePending = false;
    final intent = ++_playbackIntent;
    _startingPlayback = true;
    _pendingPlaybackVolume = volume;
    _pendingPlaybackMuted = muted;
    rtpError = null;
    _changed();
    try {
      await setRtpOptIn(true);
      if (intent != _playbackIntent || _disposed) return;
      await startRtp();
      if (intent != _playbackIntent || _disposed) {
        await stopRtp();
        return;
      }
      if (rtp.session == null || !rtp.active) {
        throw StateError(rtp.error ?? 'Unable to connect to the speaker.');
      }
      _pendingPlaybackSession = rtp.session;
      _playbackDeadline = Timer(const Duration(seconds: 60), () {
        if (_pendingPlaybackSession == null) return;
        rtpError = 'The speaker did not become ready. Try turning it on again.';
        unawaited(stopRtp().catchError((_) {}));
      });
      _continuePlayback();
    } catch (_) {
      playbackRequested = false;
      rethrow;
    } finally {
      _startingPlayback = false;
      _changed();
    }
  }

  void _cancelPlaybackIntent() {
    ++_playbackIntent;
    ++_volumeIntent;
    _pendingPlaybackSession = null;
    _pendingPlaybackVolume = null;
    _playbackDeadline?.cancel();
  }

  void _continuePlayback() {
    final session = _pendingPlaybackSession;
    if (session == null) return;
    if (rtp.session != session ||
        !['preparing', 'readyMuted'].contains(rtp.state) ||
        (rtp.generation != null && rtp.generation != 1) ||
        (muteFeedback != null && _heartbeatDoubtRevision == null)) {
      _cancelPlaybackIntent();
      return;
    }
    if (!canUnmute || _applyingPlaybackVolume) return;
    _applyingPlaybackVolume = true;
    unawaited(_finishPlayback(session, _playbackIntent));
  }

  Future<void> _finishPlayback(String session, int intent) async {
    try {
      int? volume;
      do {
        volume = _pendingPlaybackVolume;
        if (volume == null || intent != _playbackIntent) return;
        await setPlaybackVolume(volume);
      } while (intent == _playbackIntent && volume != _pendingPlaybackVolume);
      if (intent != _playbackIntent ||
          rtp.session != session ||
          rtp.generation != 1 ||
          !canUnmute) {
        return;
      }
      if (rtp.percent != volume) {
        throw StateError('Speaker volume could not be confirmed.');
      }
      final muted = _pendingPlaybackMuted;
      _cancelPlaybackIntent();
      if (!_priorityAllowsPlayback) {
        await standbyRtp(muted: _priorityGroupMuted);
      } else if (muted || _priorityGroupMuted) {
        if (rtp.outputMuted != true) await muteRtp();
      } else {
        await unmuteRtp();
      }
    } catch (error) {
      if (_pendingPlaybackSession == session || rtp.session == session) {
        _cancelPlaybackIntent();
        playbackRequested = false;
        rtpError = error is StateError
            ? error.message.toString()
            : error.toString();
      }
    } finally {
      _applyingPlaybackVolume = false;
      _changed();
    }
  }

  Future<void> setPlaybackVolume(int target) async {
    if (target < 0 || target > 100) throw ArgumentError.value(target);
    final intent = ++_volumeIntent;
    final session = rtp.session;
    final generation = rtp.generation;
    while (rtp.percent != null && rtp.percent != target) {
      if (_disposed ||
          intent != _volumeIntent ||
          rtp.session != session ||
          rtp.generation != generation ||
          !['playing', 'readyMuted'].contains(rtp.state) ||
          muteFeedback != null) {
        return;
      }
      final current = rtp.percent!;
      await setRtpVolume(
        target.clamp(
          (current - 10).clamp(0, 100),
          (current + 10).clamp(0, 100),
        ),
      );
      if (intent == _volumeIntent && rtp.percent == current) {
        throw StateError('Speaker volume could not be confirmed.');
      }
    }
  }

  Future<void> setPlaybackLevels({
    required double groupVolume,
    required double speakerLevel,
    double sourceLevel = 100,
  }) {
    return setPlaybackVolume(
      _combinedLevel(groupVolume, speakerLevel, sourceLevel),
    );
  }

  static int _combinedLevel(
    double groupVolume,
    double speakerLevel,
    double sourceLevel,
  ) {
    for (final level in [groupVolume, speakerLevel, sourceLevel]) {
      if (!level.isFinite || level < 0 || level > 100) {
        throw ArgumentError.value(level);
      }
    }
    return (groupVolume * speakerLevel * sourceLevel / 10000).round();
  }

  static Future<ProcessResult> _boundedRun(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 65),
  }) async {
    final process = await Process.start(executable, arguments);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(process.pid, exitCode, await output, await errors);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  void attachApp() {
    if (!available || _heartbeat != null) return;
    unawaited(_poll());
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_poll());
    });
  }

  Future<void> _poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    final revision = _stateRevision;
    try {
      final response = await rtpRequest('app-heartbeat', {'app_pid': pid});
      if (revision == _stateRevision) {
        // The controller answers again, so its own status replaces the doubt a failed heartbeat left behind.
        if (_heartbeatDoubtRevision == _muteRevision) muteFeedback = null;
        _heartbeatDoubtRevision = null;
        if (_heartbeatFailed) rtpError = null;
        _heartbeatFailed = false;
        _accept(response);
      }
    } catch (error) {
      if (revision == _stateRevision) {
        rtpError = error.toString();
        _heartbeatFailed = true;
        if (rtp.active && muteFeedback == null) {
          muteFeedback = 'Mute unconfirmed';
          _heartbeatDoubtRevision = _muteRevision;
        }
      }
    } finally {
      _polling = false;
      _changed();
    }
  }

  Future<Map<String, dynamic>> rtpRequest(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    if (!available) throw StateError('RTP laptop audio requires Linux');
    final result = await _run([
      'rtp',
      jsonEncode({'version': 1, 'action': action, ...fields}),
    ]);
    Map<String, dynamic> response;
    try {
      response = jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
    } catch (_) {
      throw StateError('Install the current Syren laptop audio package.');
    }
    if (response['version'] != 1) {
      if (rtp.active && action != 'stop') {
        unawaited(rtpRequest('stop').catchError((_) => <String, dynamic>{}));
      }
      throw StateError('Audio protocol mismatch. Update both audio packages.');
    }
    if (result.exitCode != 0 ||
        (response['error'] != null && !response.containsKey('state'))) {
      throw StateError(response['error']?.toString() ?? 'Audio command failed');
    }
    return response;
  }

  void _accept(Map<String, dynamic> response) {
    final next = RtpStatus(response);
    if (next.session == rtp.session &&
        next.generation != null &&
        rtp.generation != null &&
        next.generation! < rtp.generation!) {
      return;
    }
    // A generation that moved without this app asking means the receiver muted itself for recovery.
    final recovering =
        (next.state == 'recoveringMuted' && rtp.state != 'recoveringMuted') ||
        (next.session == rtp.session &&
            (next.generation ?? 0) > (rtp.generation ?? 0) &&
            (rtp.generation ?? 0) > 0 &&
            muteFeedback == null &&
            !_priorityChanging);
    if (next.state == 'recoveryPending' ||
        (next.state == 'idle' && rtp.active)) {
      playbackRequested = false;
      _prioritySuspended = false;
      _resumePending = false;
    } else if (recovering) {
      // The switch stays on, so the coordinator confirms volume again once the receiver is ready.
      _prioritySuspended = false;
      _resumePending = playbackRequested;
    }
    rtp = next;
    if (muteFeedback != null &&
        next.session == _muteSession &&
        next.muted == true &&
        _minimumMuteGeneration != null &&
        (next.generation ?? -1) >= _minimumMuteGeneration!) {
      muteFeedback = null;
      _muteTimer?.cancel();
    }
    if (next.state == 'idle') {
      muteFeedback = null;
      _heartbeatDoubtRevision = null;
      _muteTimer?.cancel();
    }
    _continuePlayback();
    _changed();
  }

  Future<void> startRtp() async {
    await _update('start', {'app_pid': pid});
  }

  Future<void> _update(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    final revision = ++_stateRevision;
    final response = await rtpRequest(action, fields);
    if (revision == _stateRevision) _accept(response);
  }

  Future<void> stopRtp() {
    playbackRequested = false;
    _prioritySuspended = false;
    _resumePending = false;
    _cancelPlaybackIntent();
    return _update('stop');
  }

  Future<void> recoverRtp({bool confirmSnapclientRestore = false}) async {
    await _update('recover', {
      'confirm_snapclient_restore': confirmSnapclientRestore,
    });
  }

  Future<void> muteRtp() async {
    _cancelPlaybackIntent();
    // An explicit mute outranks a pending automatic resume.
    _resumePending = false;
    final revision = ++_muteRevision;
    final stateRevision = ++_stateRevision;
    _muteSession = rtp.session;
    _minimumMuteGeneration = (rtp.generation ?? 0) + 1;
    _heartbeatDoubtRevision = null;
    muteFeedback = 'Muting';
    _muteTimer?.cancel();
    _muteTimer = Timer(const Duration(seconds: 1), () {
      if (revision == _muteRevision && muteFeedback != null) {
        muteFeedback = 'Mute unconfirmed';
        _changed();
      }
    });
    _changed();
    try {
      final response = await rtpRequest('mute');
      if (revision == _muteRevision && stateRevision == _stateRevision) {
        _accept(response);
      }
    } catch (error) {
      rtpError = error.toString();
      _changed();
    }
  }

  Future<void> standbyRtp({bool muted = false}) async {
    if (_priorityChanging) return;
    _priorityChanging = true;
    try {
      await _update('standby', {
        'session': rtp.session,
        'generation': rtp.generation,
        'muted': muted,
      });
      if (rtp.data['selected_source'] != 'snapcast' || rtp.muted != true) {
        throw StateError('Speaker source selection was not confirmed.');
      }
      _prioritySuspended = true;
      _standbyMuted = muted;
      _resumePending = false;
    } catch (_) {
      playbackRequested = false;
      rethrow;
    } finally {
      _priorityChanging = false;
      _changed();
    }
  }

  Future<void> unmuteRtp() async {
    if (!_priorityAllowsPlayback) {
      await standbyRtp();
      return;
    }
    if (!canUnmute) {
      throw StateError('Wait for confirmed mute and receiver readiness.');
    }
    await _update('unmute', {
      'session': rtp.session,
      'generation': rtp.generation,
    });
  }

  Future<void> setRtpVolume(int percent) async {
    await _update('volume', {
      'session': rtp.session,
      'generation': rtp.generation,
      'percent': percent,
    });
  }

  Future<void> setRtpOptIn(bool enabled) async {
    final revision = ++_stateRevision;
    await rtpRequest('opt-in', {'enabled': enabled});
    final response = await rtpRequest('status');
    if (revision == _stateRevision) _accept(response);
  }

  bool get canUnmute =>
      muteFeedback == null &&
      rtp.state == 'readyMuted' &&
      rtp.muted == true &&
      !rtp.muteUnconfirmed &&
      rtp.data['graph_healthy'] == true;

  // Errors raised outside the service, such as by the coordinator, stay visible until playback is enabled again.
  void reportError(String message) {
    rtpError = message;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _cancelPlaybackIntent();
    _disposed = true;
    _heartbeat?.cancel();
    _muteTimer?.cancel();
    if (available) {
      unawaited(
        rtpRequest('close', {
          'app_pid': pid,
        }).catchError((_) => <String, dynamic>{}),
      );
    }
    super.dispose();
  }

  Future<bool?> status() async {
    if (!available) {
      return null;
    }
    try {
      final result = await _run(['status']);
      if (result.exitCode != 0) {
        return null;
      }
      return result.stdout.toString().trim() == 'enabled';
    } on ProcessException {
      return null;
    }
  }

  Future<bool> setEnabled(bool enabled) async {
    if (!available) {
      return false;
    }
    try {
      final result = await _run([enabled ? 'enable' : 'disable']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  Future<ProcessResult> _run(List<String> arguments) async {
    try {
      return await _runner(_executable, arguments);
    } on ProcessException {
      return _runner(_fallbackExecutable, arguments);
    }
  }
}

class RtpStatus {
  const RtpStatus(this.data);

  final Map<String, dynamic> data;
  String get state => data['state'] as String? ?? 'idle';
  String? get session => data['session'] as String?;
  int? get generation => data['generation'] as int?;
  bool? get muted => data['muted'] as bool?;
  bool? get outputMuted =>
      data.containsKey('output_muted') ? data['output_muted'] as bool? : muted;
  int? get percent => data['percent'] as int?;
  bool get muteUnconfirmed => data['mute_unconfirmed'] == true;
  bool get active => !['idle', 'recoveryPending'].contains(state);
  Map<String, dynamic> get preferences =>
      data['preferences'] as Map<String, dynamic>? ?? const {};
  bool get optedIn => preferences['opt_in'] == true;
  Map<String, dynamic>? get pairing =>
      preferences['pairing'] as Map<String, dynamic>?;
  String? get error => data['error'] as String?;

  String get label => switch (state) {
    'idle' => 'Stopped',
    'preparing' => 'Preparing, muted startup',
    'readyMuted' =>
      muted == true ? 'Ready, mute confirmed' : 'Mute unconfirmed',
    'playing' => 'Playing through RTP',
    'recoveringMuted' =>
      muted == true
          ? 'Recovering, mute confirmed'
          : 'Recovering, mute unconfirmed',
    'stopping' => 'Stopping and restoring Snapcast',
    'recoveryPending' => 'Recovery pending',
    _ => 'Unknown receiver state',
  };
}
