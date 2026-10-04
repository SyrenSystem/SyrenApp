const sourceNames = {
  'spotify': 'Spotify',
  'laptop': 'PC audio',
  'casting': 'Casting (future)',
};

String sourceName(String source) => sourceNames[source] ?? source;

/// A household profile or a guest who owns a session.
class Person {
  const Person({
    required this.id,
    required this.name,
    required this.colorIndex,
    this.followMe = false,
    this.profile,
  });

  final String id;
  final String name;

  /// Position in the person palette, or -1 for guests.
  final int colorIndex;
  final bool followMe;
  final Map<String, dynamic>? profile;

  bool get guest => profile == null;
  String get initial => name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
  String get possessive => name.endsWith('s') ? "$name'" : "$name's";
}

class Session {
  const Session({
    required this.id,
    required this.source,
    required this.destination,
    required this.state,
    required this.eligible,
    required this.claimSequence,
    required this.owner,
  });

  final String id;
  final String source;
  final String destination;
  final String state;
  final bool eligible;
  final int claimSequence;
  final Person owner;

  String get label => '${owner.possessive} ${sourceName(source)}';
}

class SpeakerState {
  const SpeakerState({
    required this.speaker,
    required this.reported,
    required this.online,
    this.selected = const [],
    this.audible = const [],
    this.reasons = const {},
    this.error,
    this.status,
  });

  final Map<String, dynamic> speaker;

  /// Whether this speaker has ever sent a receiver report.
  final bool reported;
  final bool online;
  final List<String> selected;
  final List<String> audible;
  final Map<String, String> reasons;
  final String? error;
  final Map<String, dynamic>? status;

  String get id => speaker['id'] as String;
  String get name => speaker['name'] as String? ?? 'Speaker';
  double get level => (speaker['level'] as num? ?? 100).toDouble();
}

enum RoomCondition { playing, silent, offline, empty }

enum TraceState { done, failed, waiting }

class TraceStep {
  const TraceStep(this.title, this.detail, this.state);

  final String title;
  final String detail;
  final TraceState state;
}

/// The most likely fix for a silent room.
enum RoomFix { none, unmute, enableSource, raiseVolume, checkSpeakers }

/// A playback group, shown to people as a room.
class Room {
  const Room({
    required this.group,
    required this.speakers,
    required this.audible,
    required this.condition,
    required this.reason,
    required this.trace,
    this.fix = RoomFix.none,
    this.fixSource,
  });

  final Map<String, dynamic> group;
  final List<SpeakerState> speakers;
  final List<Session> audible;
  final RoomCondition condition;

  /// A few words on why the room is silent, empty when it plays.
  final String reason;
  final List<TraceStep> trace;
  final RoomFix fix;
  final String? fixSource;

  String get id => group['id'] as String;
  String get name => group['name'] as String? ?? 'Room';
  bool get muted => group['muted'] as bool? ?? false;
  double get volume => (group['masterVolume'] as num? ?? 0).toDouble();
  List<String> get enabledSources =>
      (group['enabledSources'] as List? ?? const []).cast<String>();
  double sourceLevel(String source) =>
      ((group['sourceLevels'] as Map? ?? const {})[source] as num? ?? 100)
          .toDouble();
  int get offlineCount => speakers.where((speaker) => !speaker.online).length;
  bool get playing => condition == RoomCondition.playing;
}

/// Everything the profile screens show, worked out from the server messages.
class Household {
  Household._({
    required this.people,
    required this.sessions,
    required this.speakers,
    required this.rooms,
    required this.unassigned,
    required this.activated,
  });

  factory Household.from({
    required Map<String, dynamic> configuration,
    Map<String, dynamic>? catalogue,
    Map<String, dynamic>? receivers,
  }) {
    final profiles = _maps(configuration['profiles']);
    final people = [
      for (final (index, profile) in profiles.indexed)
        Person(
          id: profile['id'] as String,
          name: profile['name'] as String? ?? 'Profile',
          colorIndex: index,
          followMe: profile['followMe'] as bool? ?? false,
          profile: profile,
        ),
    ];
    final peopleById = {for (final person in people) person.id: person};
    final sessions = [
      for (final session in _maps(catalogue?['sessions']))
        if (session['state'] != 'ended')
          Session(
            id: session['id'] as String,
            source: session['source'] as String? ?? 'spotify',
            destination: session['destination'] as String? ?? 'house',
            state: session['state'] as String? ?? 'connected',
            eligible: session['eligible'] == true,
            claimSequence: (session['claimSequence'] as num? ?? 0).toInt(),
            owner:
                peopleById[session['ownerId']] ??
                Person(
                  id: '${session['ownerId']}',
                  name: 'Guest',
                  colorIndex: -1,
                ),
          ),
    ];
    final reports = {
      for (final receiver in _maps(receivers?['receivers']))
        '${receiver['speakerId']}': receiver,
    };
    final speakers = [
      for (final speaker in _maps(configuration['speakers']))
        _speakerState(speaker, reports[speaker['id']]),
    ];
    final speakersById = {for (final speaker in speakers) speaker.id: speaker};
    final activated = configuration['playbackActivated'] != false;
    final groups = _maps(configuration['groups']).toList();
    final rooms = [
      for (final group in groups)
        _room(
          group,
          [
            for (final identity in (group['speakerIds'] as List? ?? const []))
              ?speakersById[identity],
          ],
          sessions,
          activated,
        ),
    ];
    final grouped = {
      for (final group in groups) ...(group['speakerIds'] as List? ?? const []),
    };
    return Household._(
      people: people,
      sessions: sessions,
      speakers: speakers,
      rooms: rooms,
      unassigned: [
        for (final speaker in speakers)
          if (!grouped.contains(speaker.id)) speaker,
      ],
      activated: activated,
    );
  }

  final List<Person> people;
  final List<Session> sessions;
  final List<SpeakerState> speakers;
  final List<Room> rooms;

  /// Speakers in no room. They stay silent.
  final List<SpeakerState> unassigned;
  final bool activated;

  Person? person(String? identity) =>
      people.where((person) => person.id == identity).firstOrNull;

  List<Session> sessionsOf(String personId) => [
    for (final session in sessions)
      if (session.owner.id == personId) session,
  ];

  /// Rooms where this session can be heard right now.
  List<Room> roomsHearing(Session session) => [
    for (final room in rooms)
      if (room.audible.any((audible) => audible.id == session.id)) room,
  ];

  /// A short line on what this person is doing, for the profile picker.
  String? activity(String personId) {
    final owned = sessionsOf(personId);
    final rooms = {
      for (final session in owned)
        for (final room in roomsHearing(session)) room.name,
    };
    if (rooms.isNotEmpty) return 'Playing in ${_list(rooms.toList())}';
    if (owned.isNotEmpty) return '${sourceName(owned.first.source)} is ready';
    if (person(personId)?.followMe == true) return 'Follow me on';
    return null;
  }

  static SpeakerState _speakerState(
    Map<String, dynamic> speaker,
    Map<String, dynamic>? report,
  ) {
    final status = report?['status'] is Map<String, dynamic>
        ? report!['status'] as Map<String, dynamic>
        : null;
    List<String> texts(Object? value) => [
      for (final entry in (value is List ? value : const []))
        if (entry is String) entry,
    ];
    return SpeakerState(
      speaker: speaker,
      reported: report != null,
      online: report?['online'] == true,
      selected: texts(status?['selected']),
      audible: texts(status?['audible']),
      reasons: {
        for (final entry in (status?['reasons'] as Map? ?? const {}).entries)
          '${entry.key}': '${entry.value}',
      },
      error: status?['error'] as String?,
      status: status,
    );
  }

  static Room _room(
    Map<String, dynamic> group,
    List<SpeakerState> speakers,
    List<Session> sessions,
    bool activated,
  ) {
    final identity = group['id'] as String;
    final online = speakers.where((speaker) => speaker.online).toList();
    final audibleIds = {for (final speaker in online) ...speaker.audible};
    final audible = [
      for (final session in sessions)
        if (audibleIds.contains(session.id)) session,
    ];
    final trace = <TraceStep>[];
    Room result(
      RoomCondition condition,
      String reason, {
      RoomFix fix = RoomFix.none,
      String? fixSource,
    }) => Room(
      group: group,
      speakers: speakers,
      audible: audible,
      condition: condition,
      reason: reason,
      trace: trace,
      fix: fix,
      fixSource: fixSource,
    );
    // Marks one step as the answer and lists the ones after it as not checked.
    Room fail(
      String title,
      String detail,
      String reason, {
      RoomCondition condition = RoomCondition.silent,
      RoomFix fix = RoomFix.none,
      String? fixSource,
      List<String> later = const [],
    }) {
      trace.add(TraceStep(title, detail, TraceState.failed));
      for (final step in later) {
        trace.add(TraceStep(step, '', TraceState.waiting));
      }
      return result(condition, reason, fix: fix, fixSource: fixSource);
    }

    const sent = 'Audio is sent here';
    const playing = 'It is playing';
    const heard = 'The room can be heard';
    const priority = 'It has priority';
    const arriving = 'Audio reaches the speaker';

    if (speakers.isEmpty) {
      return fail(
        'The room has speakers',
        'Add a speaker to this room in Rooms',
        'No speakers',
        condition: RoomCondition.empty,
      );
    }
    if (online.isEmpty) {
      return fail(
        'Speakers are on',
        speakers.length == 1
            ? '${speakers.single.name} is not responding'
            : 'None of the ${speakers.length} speakers respond',
        'Offline',
        condition: RoomCondition.offline,
        fix: RoomFix.checkSpeakers,
        later: [sent, playing, heard, priority],
      );
    }
    trace.add(
      TraceStep(
        'Speakers are on',
        online.length == speakers.length
            ? speakers.length == 1
                  ? '${speakers.single.name} is online'
                  : 'All ${speakers.length} are online'
            : '${online.length} of ${speakers.length} are online',
        TraceState.done,
      ),
    );
    if (audible.isNotEmpty) {
      trace.add(
        TraceStep(
          'Playing',
          _list([for (final session in audible) session.label]),
          TraceState.done,
        ),
      );
      return result(RoomCondition.playing, '');
    }
    if (!activated) {
      return fail(
        'The system is switched on',
        'Playback starts once every speaker runs the new receiver',
        'Waiting for activation',
        later: [sent, playing, heard],
      );
    }

    final enabledSources = (group['enabledSources'] as List? ?? const [])
        .cast<String>();
    final routed = [
      for (final session in sessions)
        if (session.destination == 'house' || session.destination == identity)
          session,
    ]..sort((first, second) => second.claimSequence - first.claimSequence);
    if (routed.isEmpty) {
      return fail(
        sent,
        'Pick SyrenSystem or SyrenSystem · ${group['name']} in Spotify',
        'Nothing playing',
        later: [playing, heard],
      );
    }
    final enabled = [
      for (final session in routed)
        if (enabledSources.contains(session.source)) session,
    ];
    if (enabled.isEmpty) {
      final newest = routed.first;
      return fail(
        sent,
        '${newest.label} is playing, but ${sourceName(newest.source)} is off in this room',
        '${sourceName(newest.source)} is off here',
        fix: RoomFix.enableSource,
        fixSource: newest.source,
        later: [playing, heard],
      );
    }
    final newest = enabled.first;
    trace.add(
      TraceStep(
        sent,
        '${newest.label} · ${newest.destination == 'house' ? 'whole house' : 'this room'}',
        TraceState.done,
      ),
    );

    final eligible = [
      for (final session in enabled)
        if (session.eligible) session,
    ];
    if (eligible.isEmpty) {
      final paused = newest.source == 'spotify' && newest.state != 'playing';
      return fail(
        playing,
        paused
            ? '${newest.owner.name} paused Spotify'
            : 'Waiting for ${newest.label} to connect',
        paused ? 'Paused' : 'Waiting for ${sourceName(newest.source)}',
        later: [heard, priority],
      );
    }
    trace.add(
      TraceStep(
        playing,
        _list([for (final session in eligible) session.label]),
        TraceState.done,
      ),
    );

    final volume = (group['masterVolume'] as num? ?? 0).toDouble();
    if (group['muted'] == true) {
      return fail(
        heard,
        'The room is muted',
        'Muted',
        fix: RoomFix.unmute,
        later: [priority],
      );
    }
    if (volume <= 0) {
      return fail(
        heard,
        'The room volume is at 0',
        'Volume at 0',
        fix: RoomFix.raiseVolume,
        later: [priority],
      );
    }
    final levels = (group['sourceLevels'] as Map? ?? const {});
    final quiet = [
      for (final session in eligible)
        if ((levels[session.source] as num? ?? 100) <= 0) session,
    ];
    if (quiet.length == eligible.length) {
      return fail(
        heard,
        '${sourceName(quiet.first.source)} is set to 0 in this room',
        '${sourceName(quiet.first.source)} at 0',
        fix: RoomFix.raiseVolume,
        later: [priority],
      );
    }
    final reasons = [
      for (final speaker in online)
        for (final session in eligible) speaker.reasons[session.id],
    ];
    if (reasons.isNotEmpty &&
        reasons.every((reason) => reason == 'zero desired gain')) {
      final follower = eligible
          .where((session) => session.owner.followMe)
          .firstOrNull;
      if (follower != null) {
        return fail(
          heard,
          'Follow me is on and ${follower.owner.name} is not close enough',
          'Follow me moved on',
          later: [priority],
        );
      }
      return fail(
        heard,
        'The speaker volume is at 0',
        'Volume at 0',
        later: [priority],
      );
    }
    trace.add(TraceStep(heard, 'Volume ${volume.round()}', TraceState.done));

    final selected = {for (final speaker in online) ...speaker.selected};
    final chosen = eligible
        .where((session) => selected.contains(session.id))
        .toList();
    if (chosen.isEmpty) {
      if (reasons.every((reason) => reason == null)) {
        return fail(
          priority,
          'Waiting for the speaker to report back',
          'Waiting for the speaker',
        );
      }
      final winner = sessions
          .where((session) => selected.contains(session.id))
          .firstOrNull;
      return fail(
        priority,
        winner == null
            ? 'Another source or a newer claim has the room'
            : '${winner.label} has the room',
        winner == null
            ? 'Another source has priority'
            : '${winner.label} has priority',
      );
    }
    trace.add(
      TraceStep(priority, 'Nothing higher is playing', TraceState.done),
    );
    final errors = [
      for (final speaker in online)
        if (speaker.error case final error?) error,
    ];
    return fail(
      arriving,
      errors.isNotEmpty
          ? errors.first
          : 'Selected, but no audio is arriving yet',
      'No audio arriving',
      fix: RoomFix.checkSpeakers,
    );
  }

  static Iterable<Map<String, dynamic>> _maps(Object? value) sync* {
    if (value is! List) return;
    for (final entry in value) {
      if (entry is Map<String, dynamic>) yield entry;
    }
  }
}

String _list(List<String> items) {
  if (items.length <= 1) return items.join();
  return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}
