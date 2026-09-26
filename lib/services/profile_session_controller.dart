import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'mqtt_service.dart';
import 'volume_change_queue.dart';
import '../models/system_configuration.dart';

class ProfileSessionController extends ChangeNotifier {
  ProfileSessionController(this.mqtt, this.storage) {
    instanceId = mqtt.clientId;
    mqtt.onProfileMessage = receive;
    mqtt.onProfileDistance = reportDistance;
    mqtt.onProfileReset = reset;
  }

  final MqttService mqtt;
  final Box<String> storage;
  late final String instanceId;
  Map<String, dynamic>? configuration;
  Map<String, dynamic>? catalogue;
  Map<String, dynamic>? receivers;
  Map<String, dynamic>? linkStatus;
  String? selectedId;
  String? lease;
  String? error;
  bool serverOnline = true;
  String? pcSessionId;
  String? pcOwner;
  List<dynamic>? _pcTransports;
  Process? _sender;
  Timer? _heartbeat;
  int _pcSequence = 1;
  int _positionSequence = DateTime.now().microsecondsSinceEpoch;
  bool _disposed = false;
  int? _readyGeneration;
  bool _readyPending = false;
  Timer? _readyRetry;
  final _volumes = VolumeChangeQueue(null);

  bool get pcAvailable => Platform.isLinux;

  List<Map<String, dynamic>> get profiles =>
      (configuration?['profiles'] as List? ?? []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get groups =>
      (configuration?['groups'] as List? ?? []).cast<Map<String, dynamic>>();
  Map<String, dynamic>? get selected =>
      profiles.where((profile) => profile['id'] == selectedId).firstOrNull;

  void receive(String kind, Map<String, dynamic> message) {
    if (_disposed) return;
    if (kind == 'Configuration') {
      if (message['protocolVersion'] != 3) return;
      final previous = configuration;
      if (previous != null &&
          message['stateId'] == previous['stateId'] &&
          ((message['generation'] as int) < (previous['generation'] as int) ||
              (message['generation'] == previous['generation'] &&
                  (message['revision'] as int) <=
                      (previous['revision'] as int)))) {
        return;
      }
      if (previous?['stateId'] != message['stateId']) {
        selectedId = storage.get('profile:${message['stateId']}');
        lease = null;
        catalogue = receivers = null;
        _readyGeneration = null;
      }
      configuration = message;
      _volumes.updateConfiguration(
        SystemConfiguration(
          stateId: '${message['stateId']}:${message['generation']}',
          revision: message['revision'] as int,
          speakers: const [],
          groups: const [],
          sources: const [],
        ),
      );
      _announceController();
      if (pcSessionId != null &&
          previous?['generation'] != message['generation']) {
        _pcEvent('reconcile');
      }
      if (selected == null) {
        selectedId = null;
        lease = null;
      }
    } else if (kind == 'Catalogue' || kind == 'Receivers') {
      if (message['generation'] != configuration?['generation']) return;
      final previous = kind == 'Catalogue' ? catalogue : receivers;
      if (previous != null &&
          previous['generation'] == message['generation'] &&
          (previous['revision'] as int) >= (message['revision'] as int)) {
        return;
      }
      if (kind == 'Catalogue') {
        catalogue = message;
        if (pcSessionId != null &&
            (message['sessions'] as List? ?? []).any(
              (session) =>
                  session['id'] == pcSessionId && session['state'] == 'ended',
            )) {
          unawaited(stopPc());
        }
      } else {
        receivers = message;
      }
    } else if (kind == 'SpotifyLinkStatus') {
      if (linkStatus?['ticket'] != null &&
          linkStatus?['ticket'] != message['ticket']) {
        return;
      }
      linkStatus = message;
    } else if (kind == 'ServerStatus') {
      final online = message['online'] == true;
      if (online == serverOnline) return;
      serverOnline = online;
    } else {
      return;
    }
    notifyListeners();
  }

  // The server needs this announcement once per generation before it allows activation.
  void _announceController() {
    final current = configuration;
    if (_disposed ||
        current == null ||
        _readyPending ||
        _readyGeneration == current['generation']) {
      return;
    }
    _readyPending = true;
    _readyRetry?.cancel();
    final generation = current['generation'] as int;
    unawaited(
      command('controllerReady', {
        'capabilities': [
          'profiles',
          'source-settings',
          'position-ownership',
          'pc-ownership',
        ],
      }).then(
        (_) {
          _readyPending = false;
          _readyGeneration = generation;
          _announceController();
        },
        onError: (Object failure) {
          _readyPending = false;
          if (!_disposed) {
            _readyRetry = Timer(
              const Duration(seconds: 2),
              _announceController,
            );
          }
        },
      ),
    );
  }

  /// Forgets the server state when this broker no longer offers profile playback.
  void reset() {
    if (_disposed) return;
    _readyRetry?.cancel();
    unawaited(stopPc());
    configuration = catalogue = receivers = linkStatus = null;
    selectedId = lease = error = null;
    _readyGeneration = null;
    _readyPending = false;
    notifyListeners();
  }

  Future<Map<String, dynamic>> command(
    String action,
    Map<String, dynamic> fields,
  ) async {
    final current = configuration;
    if (current == null) throw StateError('Waiting for server configuration');
    if (!serverOnline) throw StateError('Server is offline');
    try {
      final response = await mqtt.profileCommand({
        'stateId': current['stateId'],
        'generation': current['generation'],
        'expectedRevision': current['revision'],
        'action': action,
        ...fields,
      });
      final revision = response['revision'] as int;
      if ((configuration?['revision'] as int? ?? -1) < revision) {
        final applied = Completer<void>();
        void changed() {
          if ((configuration?['revision'] as int? ?? -1) >= revision &&
              !applied.isCompleted) {
            applied.complete();
          }
        }

        addListener(changed);
        try {
          await applied.future.timeout(const Duration(seconds: 5));
        } finally {
          removeListener(changed);
        }
      }
      error = null;
      return response;
    } catch (failure) {
      error = failure.toString();
      rethrow;
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> setVolume(
    String identity,
    double value, {
    String? source,
    bool speaker = false,
  }) async {
    await _volumes.enqueue(
      '${speaker ? 'speaker' : 'group'}:$identity:$source',
      (_) async {
        Map<String, dynamic> response;
        if (speaker) {
          response = await command('level', {
            'speakerId': identity,
            'level': value,
          });
        } else {
          final group = groups
              .where((group) => group['id'] == identity)
              .firstOrNull;
          if (group == null) throw const VolumeChangeSuperseded();
          response = await command('group', {
            ...group,
            'groupId': identity,
            if (source == null) 'masterVolume': value,
            if (source != null)
              'sourceLevels': {...group['sourceLevels'] as Map, source: value},
          });
        }
        return CommandResult.fromJson(response);
      },
    );
  }

  Future<void> select(String profileId) async {
    lease = null;
    final result = await command('select', {
      'profileId': profileId,
      'instanceId': instanceId,
      'selectionSequence': DateTime.now().microsecondsSinceEpoch,
    });
    selectedId = profileId;
    lease = result['lease'] as String?;
    await storage.put('profile:${configuration!['stateId']}', profileId);
    if (lease != null) {
      await storage.put('positionLease:${configuration!['stateId']}', lease!);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> saveProfile(Map<String, dynamic> profile) async {
    await command('profile', {'profile': profile});
  }

  Future<void> linkSpotify() async {
    linkStatus = null;
    final result = await command('linkSpotify', {'profileId': selectedId});
    linkStatus ??= {
      'ticket': (result['linkRequest'] as Map)['ticket'],
      'status': 'starting',
    };
    if (!_disposed) notifyListeners();
  }

  bool reportDistance(String sensorId, double distance) {
    if (lease == null ||
        selected == null ||
        !distance.isFinite ||
        distance < 0) {
      return false;
    }
    final speakers = (configuration!['speakers'] as List)
        .cast<Map<String, dynamic>>();
    final speaker = speakers
        .where((speaker) => speaker['sensorId'] == sensorId.toLowerCase())
        .firstOrNull;
    if (speaker == null) return false;
    return mqtt.publish('SyrenSystem/v3/Position', {
      'generation': configuration!['generation'],
      'profileId': selectedId,
      'instanceId': instanceId,
      'lease': lease,
      'sequence': ++_positionSequence,
      'distances': {sensorId.toLowerCase(): distance},
    });
  }

  Future<void> startPc(
    String destination, {
    String? speakerId,
    String? receiverAddress,
  }) async {
    if (!Platform.isLinux || selected == null || pcSessionId != null) return;
    String? senderAddress;
    if (receiverAddress != null) {
      final route = await Process.run('ip', [
        '-j',
        'route',
        'get',
        receiverAddress,
      ]);
      senderAddress =
          (jsonDecode(route.stdout as String) as List).first['prefsrc']
              as String;
    }
    final response = await command('pc', {
      'profileId': selectedId,
      'instanceId': instanceId,
      'destination': destination,
      'speakerId': speakerId,
      'receiverAddress': receiverAddress,
      'senderAddress': senderAddress,
    });
    pcSessionId = response['sessionId'] as String;
    _pcTransports = response['transports'] as List<dynamic>;
    pcOwner = selectedId;
    _pcSequence = 1;
    try {
      final helper = File(
        '${File(Platform.resolvedExecutable).parent.path}/lib/syren-audio/profile_pc_sender.py',
      );
      final source = File('linux/audio/profile_pc_sender.py');
      final script = helper.existsSync() ? helper.path : source.absolute.path;
      _sender = await Process.start('python3', [script]);
      _sender!.stdin.writeln(
        jsonEncode({
          'host': mqtt.connectedHost,
          'sessionId': pcSessionId,
          'transports': response['transports'],
        }),
      );
      _sender!.stderr.transform(utf8.decoder).listen((message) {
        error = message.trim();
        if (!_disposed) notifyListeners();
      });
      final process = _sender!;
      unawaited(
        process.stdin.done.then(
          (_) {},
          onError: (Object failure) {
            unawaited(stopPc());
          },
        ),
      );
      unawaited(
        process.exitCode.then((_) {
          if (identical(process, _sender)) unawaited(stopPc());
        }),
      );
      _heartbeat = Timer.periodic(
        const Duration(milliseconds: 750),
        (_) => sendPcHeartbeat(),
      );
    } catch (_) {
      await stopPc();
      rethrow;
    }
    notifyListeners();
  }

  @visibleForTesting
  void sendPcHeartbeat() {
    _sender?.stdin.writeln('alive');
    _pcEvent('heartbeat');
  }

  void _pcEvent(String action) {
    final current = configuration;
    if (pcSessionId == null || current == null) return;
    mqtt.publish('SyrenSystem/v3/Lifecycle', {
      'generation': current['generation'],
      'sessionId': pcSessionId,
      'producerId': instanceId,
      // A heartbeat repeats the latest sequence so it never takes one from a real event.
      'eventSequence': action == 'heartbeat' ? _pcSequence : ++_pcSequence,
      'action': action,
      if (action == 'reconcile' || action == 'heartbeat')
        'transports': _pcTransports,
    });
  }

  Future<void> stopPc() async {
    _heartbeat?.cancel();
    _pcEvent('end');
    pcSessionId = pcOwner = null;
    _pcTransports = null;
    final process = _sender;
    _sender = null;
    if (process != null) {
      try {
        await process.stdin.close();
      } on IOException {
        // The sender may have already closed its input.
      }
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _readyRetry?.cancel();
    _volumes.dispose();
    unawaited(stopPc());
    mqtt.onProfileMessage = null;
    mqtt.onProfileDistance = null;
    mqtt.onProfileReset = null;
    super.dispose();
  }
}
