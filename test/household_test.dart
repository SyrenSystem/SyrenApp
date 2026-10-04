import 'package:final_project/models/household.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> profile(String id, String name, {bool followMe = false}) =>
    {
      'id': id,
      'name': name,
      'followMe': followMe,
      'sourcePriority': ['spotify', 'laptop', 'casting'],
      'overlap': <Object>[],
    };

Map<String, dynamic> group(
  String id,
  String name,
  List<String> speakers, {
  List<String> sources = const ['spotify', 'laptop'],
  bool muted = false,
  double volume = 50,
  Map<String, dynamic> levels = const {},
}) => {
  'id': id,
  'name': name,
  'speakerIds': speakers,
  'enabledSources': sources,
  'sourceLevels': levels,
  'masterVolume': volume,
  'muted': muted,
};

Map<String, dynamic> session(
  String id,
  String owner,
  String source, {
  String destination = 'house',
  String state = 'playing',
  bool eligible = true,
  int claim = 1,
}) => {
  'id': id,
  'ownerId': owner,
  'source': source,
  'destination': destination,
  'state': state,
  'eligible': eligible,
  'claimSequence': claim,
};

Map<String, dynamic> receiver(
  String speaker, {
  bool online = true,
  List<String> selected = const [],
  List<String> audible = const [],
  Map<String, String> reasons = const {},
}) => {
  'speakerId': speaker,
  'online': online,
  'status': {
    'selected': selected,
    'audible': audible,
    'reasons': reasons,
    'error': null,
  },
};

Household household({
  List<Map<String, dynamic>> groups = const [],
  List<Map<String, dynamic>> sessions = const [],
  List<Map<String, dynamic>> receivers = const [],
  bool activated = true,
  bool mayaFollows = false,
}) => Household.from(
  configuration: {
    'playbackActivated': activated,
    'profiles': [
      profile('maya', 'Maya', followMe: mayaFollows),
      profile('jonas', 'Jonas'),
    ],
    'speakers': [
      {'id': 'office', 'name': 'Office speaker', 'level': 40},
      {'id': 'kitchen', 'name': 'Kitchen speaker', 'level': 30},
      {'id': 'spare', 'name': 'Spare', 'level': 30},
    ],
    'groups': groups,
  },
  catalogue: {'sessions': sessions},
  receivers: {'receivers': receivers},
);

void main() {
  test('a room with an audible session plays and names its owner', () {
    final result = household(
      groups: [
        group('office-room', 'Office', ['office']),
      ],
      sessions: [session('pc', 'jonas', 'laptop')],
      receivers: [
        receiver('office', selected: ['pc'], audible: ['pc']),
      ],
    );
    final room = result.rooms.single;
    expect(room.condition, RoomCondition.playing);
    expect(room.audible.single.owner.name, 'Jonas');
    expect(result.activity('jonas'), 'Playing in Office');
    expect(result.activity('maya'), isNull);
  });

  test('a source that is off in the room is the answer and the fix', () {
    final result = household(
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen'], sources: ['spotify']),
      ],
      sessions: [session('pc', 'maya', 'laptop')],
      receivers: [
        receiver('kitchen', reasons: {'pc': 'source disabled'}),
      ],
    );
    final room = result.rooms.single;
    expect(room.condition, RoomCondition.silent);
    expect(room.reason, 'PC audio is off here');
    expect(room.fix, RoomFix.enableSource);
    expect(room.fixSource, 'laptop');
    expect(room.trace.map((step) => step.state), [
      TraceState.done,
      TraceState.failed,
      TraceState.waiting,
      TraceState.waiting,
    ]);
  });

  test('a muted room says so and offers to unmute', () {
    final room = household(
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen'], muted: true),
      ],
      sessions: [session('music', 'maya', 'spotify')],
      receivers: [
        receiver('kitchen', reasons: {'music': 'zero desired gain'}),
      ],
    ).rooms.single;
    expect(room.reason, 'Muted');
    expect(room.fix, RoomFix.unmute);
  });

  test('paused Spotify is reported as paused, not broken', () {
    final room = household(
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen']),
      ],
      sessions: [
        session('music', 'maya', 'spotify', state: 'paused', eligible: false),
      ],
      receivers: [
        receiver('kitchen', reasons: {'music': 'playback unavailable'}),
      ],
    ).rooms.single;
    expect(room.reason, 'Paused');
    expect(room.trace.last.title, 'It has priority');
    expect(
      room.trace.where((step) => step.state == TraceState.failed).single.detail,
      'Maya paused Spotify',
    );
  });

  test('a room whose speakers do not report is offline', () {
    final result = household(
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen']),
      ],
      receivers: [receiver('kitchen', online: false)],
    );
    final room = result.rooms.single;
    expect(room.condition, RoomCondition.offline);
    expect(room.reason, 'Offline');
    expect(room.fix, RoomFix.checkSpeakers);
  });

  test('Follow me explains a silent room when the listener is away', () {
    final room = household(
      mayaFollows: true,
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen']),
      ],
      sessions: [session('music', 'maya', 'spotify')],
      receivers: [
        receiver('kitchen', reasons: {'music': 'zero desired gain'}),
      ],
    ).rooms.single;
    expect(room.reason, 'Follow me moved on');
    expect(
      room.trace.where((step) => step.state == TraceState.failed).single.detail,
      'Follow me is on and Maya is not close enough',
    );
  });

  test('a chosen session that is not heard points at the speaker', () {
    final room = household(
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen']),
      ],
      sessions: [
        session('music', 'maya', 'spotify', claim: 1),
        session('pc', 'jonas', 'laptop', claim: 2),
      ],
      receivers: [
        receiver(
          'kitchen',
          selected: ['pc'],
          reasons: {
            'music':
                'displaced by source priority or a newer incompatible claim',
            'pc': 'selected',
          },
        ),
      ],
    ).rooms.single;
    expect(room.reason, 'No audio arriving');
    expect(room.fix, RoomFix.checkSpeakers);
  });

  test('nothing playing and waiting for activation are told apart', () {
    final idle = household(
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen']),
      ],
      receivers: [receiver('kitchen')],
    ).rooms.single;
    expect(idle.reason, 'Nothing playing');

    final inactive = household(
      activated: false,
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen']),
      ],
      sessions: [session('music', 'maya', 'spotify')],
      receivers: [receiver('kitchen')],
    ).rooms.single;
    expect(inactive.reason, 'Waiting for activation');
  });

  test('guests and speakers outside every room are listed', () {
    final result = household(
      groups: [
        group('kitchen-room', 'Kitchen', ['kitchen']),
      ],
      sessions: [session('guest-music', 'unknown-account', 'spotify')],
      receivers: [
        receiver(
          'kitchen',
          selected: ['guest-music'],
          audible: ['guest-music'],
        ),
      ],
    );
    final guest = result.rooms.single.audible.single.owner;
    expect(guest.guest, isTrue);
    expect(guest.name, 'Guest');
    expect(guest.colorIndex, -1);
    expect(result.unassigned.map((speaker) => speaker.name), [
      'Office speaker',
      'Spare',
    ]);
  });

  test('people keep their color by profile order', () {
    final result = household();
    expect(result.people.map((person) => person.colorIndex), [0, 1]);
    expect(result.person('jonas')!.initial, 'J');
  });
}
