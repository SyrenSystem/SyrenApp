import 'package:flutter/material.dart';

import '../../models/household.dart';
import '../syren_theme.dart';
import 'profile_shell.dart';
import 'syren_widgets.dart';

const _sourceNotes = {
  'spotify': 'Music, podcasts',
  'laptop': 'Calls and videos from a computer',
  'casting': 'Not available yet',
};

/// The source pairs people can choose to mix.
const _pairs = [
  ('laptop', 'spotify', 'When PC audio starts where Spotify is playing'),
  ('spotify', 'spotify', 'When two Spotify accounts want the same room'),
  ('laptop', 'laptop', 'When two computers send PC audio to the same room'),
];

/// Source order, mixing and the household Spotify policy.
class RulesTab extends StatefulWidget {
  const RulesTab({
    super.key,
    required this.profile,
    required this.household,
    required this.me,
    required this.avatar,
  });

  final ProfileContext profile;
  final Household household;
  final Person me;
  final Widget avatar;

  @override
  State<RulesTab> createState() => _RulesTabState();
}

class _RulesTabState extends State<RulesTab> with CommandRunner {
  Map<String, dynamic> get selected => widget.me.profile!;

  List<Map<String, dynamic>> get overlap =>
      (selected['overlap'] as List? ?? const []).cast<Map<String, dynamic>>();

  bool mixes(String first, String second) => overlap.any(
    (pair) =>
        (pair['first'] == first && pair['second'] == second) ||
        (pair['first'] == second && pair['second'] == first),
  );

  Future<void> save(Map<String, dynamic> change) =>
      widget.profile.controller.saveProfile({...selected, ...change});

  Future<void> setMix(String first, String second, bool mix) {
    final changed = [
      for (final pair in overlap)
        if (!((pair['first'] == first && pair['second'] == second) ||
            (pair['first'] == second && pair['second'] == first)))
          pair,
      if (mix) {'first': first, 'second': second},
    ];
    return save({'overlap': changed});
  }

  Future<void> reorder(List<String> order, int from, int to) {
    final changed = List<String>.of(order);
    changed.insert(to, changed.removeAt(from));
    return save({'sourcePriority': changed});
  }

  @override
  Widget build(BuildContext context) {
    final order = (selected['sourcePriority'] as List? ?? const [])
        .cast<String>();
    final policies =
        widget.profile.controller.configuration?['sourcePolicies'] as Map? ??
        const {};
    return SyrenPage(
      children: [
        PageHeader(
          title: 'Rules',
          subtitle:
              'When two of your sources want the same room, the higher one wins.',
          trailing: widget.avatar,
        ),
        SyrenCard(
          padding: EdgeInsets.zero,
          child: ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) {
              if (!busy) run(() => reorder(order, from, to));
            },
            children: [
              for (final (index, source) in order.indexed)
                Material(
                  key: ValueKey(source),
                  color: Colors.transparent,
                  child: Container(
                    decoration: BoxDecoration(
                      border: index == order.length - 1
                          ? null
                          : const Border(
                              bottom: BorderSide(color: SyrenColors.divider),
                            ),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          child: Text(
                            '${index + 1}',
                            style: SyrenText.mono.copyWith(fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                sourceName(source),
                                style: SyrenText.body.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _sourceNotes[source] ?? '',
                                style: SyrenText.small,
                              ),
                            ],
                          ),
                        ),
                        ReorderableDragStartListener(
                          index: index,
                          enabled: !busy,
                          child: Semantics(
                            label: 'Drag to reorder ${sourceName(source)}',
                            child: const Padding(
                              padding: EdgeInsets.all(10),
                              child: Icon(
                                Icons.drag_handle,
                                color: SyrenColors.faint,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (final (first, second, title) in _pairs)
          SyrenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: SyrenText.label.copyWith(height: 1.35)),
                const SizedBox(height: 10),
                SegmentedChoice<bool>(
                  options: const {false: 'Newest wins', true: 'Mix'},
                  value: mixes(first, second),
                  onChanged: busy
                      ? null
                      : (mix) => run(() => setMix(first, second, mix)),
                ),
              ],
            ),
          ),
        const NoteBox(
          'Mixing only happens when everyone involved allows it. Otherwise the newest source takes the room. To play one source quieter, open a room and lower its level.',
        ),
        const MonoLabel('Whole household'),
        SyrenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'When someone resumes Spotify after a pause',
                style: SyrenText.label.copyWith(height: 1.35),
              ),
              const SizedBox(height: 10),
              // Always shows the server value, so a rejected or remote change stays visible.
              SegmentedChoice<String>(
                options: const {
                  'playing': 'Takes the room',
                  'connected': 'Waits its turn',
                },
                value: policies['spotify'] as String? ?? 'playing',
                onChanged: busy
                    ? null
                    : (value) => run(
                        () => widget.profile.controller.command('policy', {
                          'source': 'spotify',
                          'policy': value,
                        }),
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                'Takes the room: resuming counts as a fresh start. Waits its turn: anything started during the pause keeps playing until it stops.',
                style: SyrenText.small,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
