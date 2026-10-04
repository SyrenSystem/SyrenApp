import 'package:flutter/material.dart';

import '../../models/household.dart';
import '../syren_theme.dart';
import 'profile_shell.dart';
import 'room_detail_page.dart';
import 'syren_widgets.dart';

/// Rooms and the speakers in them.
class RoomsTab extends StatelessWidget {
  const RoomsTab({
    super.key,
    required this.profile,
    required this.household,
    required this.avatar,
  });

  final ProfileContext profile;
  final Household household;
  final Widget avatar;

  void edit(BuildContext context, [Room? room]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            RoomEditorPage(profile: profile, household: household, room: room),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SyrenPage(
      children: [
        PageHeader(title: 'Rooms', trailing: avatar),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'A room is a set of speakers that play together. Spotify lists each one as SyrenSystem · room name.',
            style: SyrenText.small.copyWith(fontSize: 14),
          ),
        ),
        for (final room in household.rooms)
          SyrenCard(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) =>
                    RoomDetailPage(profile: profile, roomId: room.id),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(room.name, style: SyrenText.cardTitle),
                      const SizedBox(height: 3),
                      Text(
                        room.speakers.isEmpty
                            ? 'No speakers'
                            : room.speakers
                                  .map((speaker) => speaker.name)
                                  .join(', '),
                        style: SyrenText.small,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final source in room.enabledSources)
                            StatusChip(sourceName(source)),
                          if (room.enabledSources.isEmpty)
                            const StatusChip('No sources'),
                          if (room.offlineCount > 0)
                            StatusChip(
                              '${room.offlineCount} offline',
                              background: SyrenColors.warningBackground,
                              foreground: SyrenColors.warning,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Edit ${room.name}',
                  icon: const Icon(
                    Icons.edit_outlined,
                    color: SyrenColors.muted,
                  ),
                  onPressed: () => edit(context, room),
                ),
              ],
            ),
          ),
        SyrenButton('+ New room', onPressed: () => edit(context)),
        if (household.unassigned.isNotEmpty) ...[
          const MonoLabel('Not in a room · silent'),
          RowsCard(
            rows: [
              for (final speaker in household.unassigned)
                InfoRow(
                  label: speaker.name,
                  value: speaker.online ? 'Online' : 'Offline',
                  valueColor: speaker.online
                      ? SyrenColors.good
                      : SyrenColors.warning,
                ),
            ],
          ),
          const NoteBox(
            'Speakers outside every room never play. Add them to a room to hear them.',
          ),
        ],
      ],
    );
  }
}

/// Create or change a room: its name, speakers and allowed sources.
class RoomEditorPage extends StatefulWidget {
  const RoomEditorPage({
    super.key,
    required this.profile,
    required this.household,
    this.room,
  });

  final ProfileContext profile;
  final Household household;
  final Room? room;

  @override
  State<RoomEditorPage> createState() => _RoomEditorPageState();
}

class _RoomEditorPageState extends State<RoomEditorPage> with CommandRunner {
  late final name = TextEditingController(text: widget.room?.name ?? '');
  late final members = <String>{
    ...?widget.room?.speakers.map((speaker) => speaker.id),
  };
  late final enabled = <String>{
    ...(widget.room?.enabledSources ?? const ['spotify', 'laptop']),
  };

  Room? get room => widget.room;

  /// Other rooms each speaker is already in.
  String? otherRoom(String speakerId) => widget.household.rooms
      .where(
        (other) =>
            other.id != room?.id &&
            other.speakers.any((speaker) => speaker.id == speakerId),
      )
      .map((other) => other.name)
      .firstOrNull;

  Future<void> save() async {
    await widget.profile.controller.command('group', {
      'groupId': room?.id,
      'name': name.text.trim(),
      'speakerIds': members.toList(),
      'enabledSources': enabled.toList(),
      'sourceLevels':
          room?.group['sourceLevels'] ?? {'spotify': 100.0, 'laptop': 100.0},
      'masterVolume': room?.group['masterVolume'] ?? 100.0,
      'muted': room?.group['muted'] ?? false,
    });
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${room!.name}?'),
        content: const Text(
          'Its speakers stay set up but go silent until you add them to another room.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.profile.controller.command('deleteGroup', {
      'groupId': room!.id,
    });
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final speakers = widget.household.speakers;
    final canSave = name.text.trim().isNotEmpty && !busy;
    return Scaffold(
      body: SyrenPage(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
        children: [
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Cancel',
                  style: SyrenText.body.copyWith(color: SyrenColors.muted),
                ),
              ),
              Expanded(
                child: Text(
                  room == null ? 'New room' : 'Edit room',
                  textAlign: TextAlign.center,
                  style: SyrenText.body.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: canSave ? () => run(save) : null,
                child: Text(
                  'Save',
                  style: SyrenText.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: canSave ? SyrenColors.ink : SyrenColors.faint,
                  ),
                ),
              ),
            ],
          ),
          SyrenCard(
            radius: 16,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Name', style: SyrenText.small.copyWith(fontSize: 12)),
                TextField(
                  controller: name,
                  autofocus: room == null,
                  maxLength: 100,
                  cursorColor: SyrenColors.accent,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                    fontFamily: SyrenFonts.sans,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: SyrenColors.ink,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Kitchen',
                    counterText: '',
                    contentPadding: EdgeInsets.only(top: 4),
                  ),
                ),
              ],
            ),
          ),
          MonoLabel(
            '${members.length} ${members.length == 1 ? 'speaker' : 'speakers'} selected',
          ),
          if (speakers.isEmpty)
            const NoteBox(
              'No speakers are set up yet. Add one from Setup first.',
            )
          else
            RowsCard(
              rows: [
                for (final speaker in speakers)
                  _SpeakerChoice(
                    speaker: speaker,
                    selected: members.contains(speaker.id),
                    elsewhere: otherRoom(speaker.id),
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            if (value) {
                              members.add(speaker.id);
                            } else {
                              members.remove(speaker.id);
                            }
                          }),
                  ),
              ],
            ),
          const MonoLabel('Sources allowed here'),
          RowsCard(
            rows: [
              for (final source in const ['spotify', 'laptop'])
                ToggleRow(
                  title: sourceName(source),
                  subtitle: source == 'spotify'
                      ? 'Shows up in Spotify as SyrenSystem · ${name.text.trim().isEmpty ? 'this room' : name.text.trim()}'
                      : 'Sound from a computer running SyrenApp',
                  value: enabled.contains(source),
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                          if (value) {
                            enabled.add(source);
                          } else {
                            enabled.remove(source);
                          }
                        }),
                ),
            ],
          ),
          const NoteBox(
            'A speaker plays for one room at a time. If it is in two rooms, the room listed first in Rooms wins. Offline speakers can be added and join when they come back.',
          ),
          if (room != null)
            SyrenButton(
              'Remove this room',
              kind: ButtonKind.link,
              onPressed: busy ? null : () => run(delete),
            ),
        ],
      ),
    );
  }
}

class _SpeakerChoice extends StatelessWidget {
  const _SpeakerChoice({
    required this.speaker,
    required this.selected,
    required this.elsewhere,
    required this.onChanged,
  });

  final SpeakerState speaker;
  final bool selected;
  final String? elsewhere;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final (note, noteColor) = !speaker.online
        ? ('Offline', SyrenColors.warning)
        : elsewhere != null
        ? ('Also in $elsewhere', SyrenColors.muted)
        : ('Online', SyrenColors.muted);
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!selected),
      child: Opacity(
        opacity: speaker.online ? 1 : 0.6,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: onChanged == null
                    ? null
                    : (value) => onChanged!(value ?? false),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  speaker.name,
                  style: SyrenText.body.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(note, style: SyrenText.small.copyWith(color: noteColor)),
            ],
          ),
        ),
      ),
    );
  }
}
