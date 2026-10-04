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
  Map<String, dynamic>? pcCaptureStatus;
  Completer<void>? _pcModeChanged;
  String? _requestedPcMode;
  Process? _sender;
  Timer? _heartbeat;
  int _pcSequence = 1;
  String _pcMode = 'auto';
  int _positionSequence = DateTime.now().microsecondsSinceEpoch;
  bool _disposed = false;
  int? _readyGeneration;
  bool _readyPending = false;
  Timer? _readyRetry;
  final _volumes = VolumeChangeQueue(null);

  bool get pcAvailable => Platform.isLinux;

  String get preferredPcMode {
    final saved = storage.get('pcMode');
    return const ['auto', 'stable', 'fast'].contains(saved) ? saved! : 'auto';
  }

  String? get preferredPcSpeaker => storage.get('pcSpeaker');
  String get preferredPcDestination => storage.get('pcDestination') ?? 'house';
  String? get pcFastSpeakerId =>
      (_pcTransports ?? const [])
              .cast<Map<String, dynamic>>()
              .where((transport) => transport['kind'] == 'rtp')
              .firstOrNull?['speakerId']
          as String?;

  Future<void> rememberPcSpeaker(String? speakerId) async {
    if (speakerId == null) {
      await storage.delete('pcSpeaker');
    } else {
      await storage.put('pcSpeaker', speakerId);
    }
  }

  Future<void> setPcMode(String mode) async {
    if (!const ['auto', 'stable', 'fast'].contains(mode)) {
      throw StateError('Choose Automatic, Stable or Fast');
    }
    if (pcSessionId != null) {
      if (mode == 'fast' && pcFastSpeakerId == null) {
        throw StateError('Stop PC audio and choose a fast speaker first');
      }
      final sender = _sender;
      if (sender == null) {
        throw StateError('PC capture is unavailable');
      }
      if (_pcModeChanged != null) {
        throw StateError('A PC output change is pending');
      }
      final changed = Completer<void>();
      _pcModeChanged = changed;
      _requestedPcMode = mode;
      try {
        sender.stdin.writeln(jsonEncode({'mode': mode}));
        await changed.future.timeout(const Duration(seconds: 3));
      } finally {
        _pcModeChanged = null;
        _requestedPcMode = null;
      }
    }
    await storage.put('pcMode', mode);
    if (!_disposed) notifyListeners();
  }

  @visibleForTesting
  void receivePcCaptureStatus(Map<String, dynamic> status) {
    if (pcSessionId == null) return;
    pcCaptureStatus = status;
    if (status['mode'] == _requestedPcMode &&
        _pcModeChanged?.isCompleted == false) {
      _pcModeChanged!.complete();
    }
    if (status['mode'] is String &&
        const ['auto', 'stable', 'fast'].contains(status['mode'])) {
      if (_pcMode != status['mode']) {
        _pcMode = status['mode'] as String;
        _pcEvent('transport');
      }
      unawaited(storage.put('pcMode', status['mode'] as String));
    }
    if (!_disposed) notifyListeners();
  }

  String pcTransportDescription(String mode) {
    final speakerId = pcFastSpeakerId;
    if (mode == 'stable') return 'Snapcast only';
    if (speakerId == null) {
      return mode == 'auto'
          ? 'Snapcast, no fast speaker selected'
          : 'Choose a fast speaker before playing';
    }
    final speakers = (configuration?['speakers'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final name =
        speakers
            .where((speaker) => speaker['id'] == speakerId)
            .firstOrNull?['name'] ??
        'speaker';
    final receiver = (receivers?['receivers'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .where((receiver) => receiver['speakerId'] == speakerId)
        .firstOrNull;
    if (receiver == null || receiver['online'] != true) {
      return 'Waiting for $name';
    }
    final status = receiver['status'] as Map<String, dynamic>;
    final inputs = (status['inputs'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .where(
          (input) =>
              input['sessionId'] == pcSessionId &&
              (input['pcMode'] ?? 'auto') == mode,
        );
    final audible = inputs
        .where(
          (input) =>
              input['receiving'] == true &&
              input['muted'] == false &&
              (input['gain'] as num) > 0,
        )
        .firstOrNull;
    if (audible == null) return 'Waiting for audio on $name';
    final isRtp = audible['clientId'] == null;
    return isRtp ? 'Low latency on $name' : 'Snapcast fallback on $name';
  }

  /// Reads the low latency pairing record that an earlier laptop audio setup left on this computer.
  @visibleForTesting
  Future<Map<String, dynamic>?> Function() readPairing = _readPairing;

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
    if (preferredPcMode == 'fast' && speakerId == null) {
      throw StateError('Choose a fast speaker before playing');
    }
    String? senderAddress;
    if (receiverAddress != null) {
      receiverAddress = await speakerAddress(receiverAddress);
      senderAddress = await _localAddressFor(receiverAddress);
    }
    final response = await command('pc', {
      'profileId': selectedId,
      'instanceId': instanceId,
      'destination': destination,
      'speakerId': speakerId,
      'receiverAddress': receiverAddress,
      'senderAddress': senderAddress,
      'desktopOutputs': true,
    });
    pcSessionId = response['sessionId'] as String;
    _pcTransports = response['transports'] as List<dynamic>;
    pcOwner = selectedId;
    _pcSequence = 1;
    _pcMode = 'auto';
    pcCaptureStatus = null;
    if (speakerId != null && receiverAddress != null) {
      await storage.put('speakerAddress:$speakerId', receiverAddress);
    }
    try {
      if (response['desktopOutputs'] != true) {
        throw StateError(
          'Update SyrenServer before using the three PC outputs',
        );
      }
      final helper = File(
        '${File(Platform.resolvedExecutable).parent.path}/lib/syren-audio/profile_pc_sender.py',
      );
      final source = File('linux/audio/profile_pc_sender.py');
      final script = helper.existsSync() ? helper.path : source.absolute.path;
      _sender = await Process.start('systemd-run', [
        '--user',
        '--pipe',
        '--wait',
        '--collect',
        '--quiet',
        '--property=LimitRTPRIO=86',
        '--property=ExitType=cgroup',
        '--',
        'python3',
        script,
      ]);
      _sender!.stdin.writeln(
        jsonEncode({
          'host': mqtt.connectedHost,
          'sessionId': pcSessionId,
          'transports': response['transports'],
          'desktopOutputs': true,
          'mode': preferredPcMode,
        }),
      );
      _sender!.stderr.transform(utf8.decoder).listen((message) {
        error = message.trim();
        if (!_disposed) notifyListeners();
      });
      final process = _sender!;
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (!identical(process, _sender)) return;
            try {
              receivePcCaptureStatus(jsonDecode(line) as Map<String, dynamic>);
            } on FormatException {
              error = 'PC capture returned invalid status';
              if (!_disposed) notifyListeners();
            }
          });
      await storage.put('pcDestination', destination);
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

  /// The address this computer last used for a speaker, or the one its pairing record names.
  Future<String?> knownSpeakerAddress(String speakerId) async {
    final saved = storage.get('speakerAddress:$speakerId');
    if (saved != null) return saved;
    final speaker = (configuration?['speakers'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .where((speaker) => speaker['id'] == speakerId)
        .firstOrNull;
    if (speaker == null) return null;
    try {
      final pairing = await readPairing();
      if (pairing == null ||
          pairing['snapclient_id'] != speaker['snapClientId']) {
        return null;
      }
      return (pairing['address'] ?? pairing['host']) as String?;
    } on Object {
      // Without the laptop audio package the address is simply typed in.
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _readPairing() async {
    if (!Platform.isLinux) return null;
    final installed =
        '${Platform.environment['HOME']}/.local/bin/syren-audio-control';
    final result = await Process.run(
      File(installed).existsSync() ? installed : 'syren-audio-control',
      [
        'rtp',
        jsonEncode({'version': 1, 'action': 'status'}),
      ],
    ).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) return null;
    final status = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return (status['preferences'] as Map<String, dynamic>?)?['pairing']
        as Map<String, dynamic>?;
  }

  // Accepts an IPv4 address or a name that resolves to one.
  @visibleForTesting
  static Future<String> speakerAddress(String text) async {
    final parsed = InternetAddress.tryParse(text);
    if (parsed != null) {
      if (parsed.type == InternetAddressType.IPv4) return parsed.address;
    } else if (text.isNotEmpty) {
      try {
        final found = await InternetAddress.lookup(
          text,
          type: InternetAddressType.IPv4,
        );
        if (found.isNotEmpty) return found.first.address;
      } on SocketException {
        // The message below covers names that do not resolve.
      }
    }
    throw StateError("Enter the low latency speaker's IPv4 address");
  }

  // Finds the address this computer uses to reach the speaker.
  static Future<String> _localAddressFor(String receiverAddress) async {
    final route = await Process.run('ip', [
      '-j',
      'route',
      'get',
      receiverAddress,
    ]);
    Object? routes;
    if (route.exitCode == 0) {
      try {
        routes = jsonDecode(route.stdout as String);
      } on FormatException {
        routes = null;
      }
    }
    final source = routes is List && routes.isNotEmpty
        ? (routes.first as Map)['prefsrc']
        : null;
    if (source is! String) {
      throw StateError(
        'This computer has no network route to $receiverAddress',
      );
    }
    return source;
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
      if (const ['reconcile', 'heartbeat', 'transport'].contains(action))
        'transports': _pcTransports,
      if (const ['reconcile', 'heartbeat', 'transport'].contains(action))
        'pcMode': _pcMode,
    });
  }

  Future<void> stopPc() async {
    _heartbeat?.cancel();
    _pcEvent('end');
    pcSessionId = pcOwner = null;
    _pcTransports = null;
    pcCaptureStatus = null;
    if (_pcModeChanged?.isCompleted == false) {
      _pcModeChanged!.completeError(
        StateError('PC audio stopped during the output change'),
      );
    }
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
