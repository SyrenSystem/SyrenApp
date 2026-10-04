import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/household.dart';
import '../app_feedback.dart';
import '../syren_theme.dart';
import 'profile_shell.dart';
import 'rooms_tab.dart';
import 'syren_widgets.dart';

/// One room: why it is quiet, its volume, its speakers and how to fix a dead speaker.
class RoomDetailPage extends StatefulWidget {
  const RoomDetailPage({
    super.key,
    required this.profile,
    required this.roomId,
  });

  final ProfileContext profile;
  final String roomId;

  @override
  State<RoomDetailPage> createState() => _RoomDetailPageState();
}

class _RoomDetailPageState extends State<RoomDetailPage> with CommandRunner {
  bool showLog = false;

  Future<void> change(Room room, Map<String, dynamic> fields) => widget
      .profile
      .controller
      .command('group', {...room.group, 'groupId': room.id, ...fields});

  void volume(Room room, double value, {String? source}) {
    unawaited(
      widget.profile.controller
          .setVolume(room.id, value, source: source)
          .catchError((Object error) {
            if (mounted) {
              showLatestSnackBar(
                context,
                SnackBar(content: Text(friendlyError(error))),
              );
            }
          }),
    );
  }

  Future<void> applyFix(Room room) async {
    switch (room.fix) {
      case RoomFix.unmute:
        await change(room, {'muted': false});
      case RoomFix.enableSource:
        await change(room, {
          'enabledSources': {...room.enabledSources, room.fixSource!}.toList(),
        });
      case RoomFix.raiseVolume:
        await change(room, {
          if (room.volume <= 0) 'masterVolume': 30.0,
          'sourceLevels': {
            ...(room.group['sourceLevels'] as Map? ?? const {}),
            for (final source in room.enabledSources)
              if (room.sourceLevel(source) <= 0) source: 100.0,
          },
        });
      case RoomFix.none:
      case RoomFix.checkSpeakers:
        break;
    }
  }

  String? fixLabel(Room room) => switch (room.fix) {
    RoomFix.unmute => 'Unmute ${room.name}',
    RoomFix.enableSource => 'Turn on ${sourceName(room.fixSource!)} here',
    RoomFix.raiseVolume => 'Turn the volume up',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    return HouseholdBuilder(
      controller: widget.profile.controller,
      builder: (context, household) {
        final room = household.rooms
            .where((room) => room.id == widget.roomId)
            .firstOrNull;
        if (room == null) {
          return const Scaffold(
            body: SyrenPage(
              children: [
                BackLink('Home'),
                Text('This room was removed', style: SyrenText.title),
              ],
            ),
          );
        }
        final (
          chipText,
          chipBackground,
          chipForeground,
        ) = switch (room.condition) {
          RoomCondition.playing => (
            'Playing',
            SyrenColors.goodBackground,
            SyrenColors.good,
          ),
          RoomCondition.offline => (
            'Offline',
            SyrenColors.warningBackground,
            SyrenColors.warning,
          ),
          _ => ('Silent', SyrenColors.chip, SyrenColors.ink),
        };
        final offline = room.speakers
            .where((speaker) => !speaker.online)
            .toList();
        final label = fixLabel(room);
        return Scaffold(
          body: SyrenPage(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
            children: [
              BackLink(
                'Home',
                trailing: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => RoomEditorPage(
                        profile: widget.profile,
                        household: household,
                        room: room,
                      ),
                    ),
                  ),
                  child: const Text(
                    'Edit',
                    style: TextStyle(
                      fontFamily: SyrenFonts.sans,
                      fontWeight: FontWeight.w600,
                      color: SyrenColors.ink,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: Text(room.name, style: SyrenText.title)),
                    StatusChip(
                      chipText,
                      background: chipBackground,
                      foreground: chipForeground,
                    ),
                  ],
                ),
              ),
              if (room.playing) _NowPlaying(room: room) else _Trace(room: room),
              if (label != null)
                SyrenButton(
                  label,
                  onPressed: busy ? null : () => run(() => applyFix(room)),
                ),
              if (offline.isNotEmpty) ..._recovery(household, room, offline),
              SyrenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LevelSlider(
                      label: 'Volume',
                      value: room.volume,
                      color: room.muted || !room.playing
                          ? SyrenColors.faint
                          : room.audible.isEmpty
                          ? SyrenColors.ink
                          : personColor(room.audible.first.owner),
                      onChanged: (value) => volume(room, value),
                    ),
                    for (final source in room.enabledSources)
                      LevelSlider(
                        label: sourceName(source),
                        value: room.sourceLevel(source),
                        suffix: '%',
                        onChanged: (value) =>
                            volume(room, value, source: source),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      room.enabledSources.isEmpty
                          ? 'No sources are turned on for this room.'
                          : 'Source levels lower one source against the room volume.',
                      style: SyrenText.small,
                    ),
                  ],
                ),
              ),
              RowsCard(
                rows: [
                  ToggleRow(
                    title: 'Mute ${room.name}',
                    value: room.muted,
                    onChanged: busy
                        ? null
                        : (value) => run(() => change(room, {'muted': value})),
                  ),
                  for (final speaker in room.speakers)
                    InfoRow(
                      label: speaker.name,
                      value: speaker.online ? 'Online' : 'Offline',
                      valueColor: speaker.online
                          ? SyrenColors.good
                          : SyrenColors.warning,
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _recovery(
    Household household,
    Room room,
    List<SpeakerState> offline,
  ) {
    final controller = widget.profile.controller;
    final title = offline.length == 1
        ? '${offline.single.name} isn\'t responding'
        : '${offline.length} speakers aren\'t responding';
    final others = household.speakers.length - offline.length;
    final hubReachable = controller.mqtt.isConnected;
    final rows = [
      (
        hubReachable,
        'Phone → hub',
        hubReachable ? 'Connected' : 'Not connected',
      ),
      (
        controller.serverOnline,
        'Hub → Syren server',
        controller.serverOnline ? 'Running' : 'Offline',
      ),
      for (final speaker in offline)
        (
          false,
          'Hub → ${speaker.name}',
          speaker.reported ? 'No reply' : 'Never seen',
        ),
    ];
    return [
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: SyrenText.heading),
            const SizedBox(height: 6),
            Text(
              others > 0 && controller.serverOnline
                  ? 'The hub and the other speakers are fine.'
                  : 'The problem may be the hub itself, so check the steps in order.',
              style: SyrenText.lead,
            ),
          ],
        ),
      ),
      RowsCard(
        rows: [
          for (final (ok, label, detail) in rows)
            Container(
              color: ok ? null : SyrenColors.badRow,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    ok ? Icons.check : Icons.close,
                    size: 18,
                    color: ok ? SyrenColors.good : SyrenColors.bad,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: SyrenText.body.copyWith(
                        fontSize: 14,
                        fontWeight: ok ? FontWeight.w400 : FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    detail,
                    style: SyrenText.mono.copyWith(
                      fontSize: 12,
                      letterSpacing: 0,
                      color: ok ? SyrenColors.muted : SyrenColors.bad,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      const MonoLabel('Try this'),
      for (final (index, step) in const [
        'Check the speaker has power and its Raspberry Pi has booted. That takes about a minute.',
        'Check its Wi-Fi. A weak signal drops the speaker, so move it closer or add an extender.',
        'If it still does not show up, restart the speaker by unplugging it for ten seconds.',
      ].indexed)
        SyrenCard(
          radius: 16,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${index + 1}',
                style: SyrenText.mono.copyWith(
                  fontSize: 14,
                  color: SyrenColors.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(step, style: SyrenText.body.copyWith(fontSize: 14)),
              ),
            ],
          ),
        ),
      Center(
        child: TextButton(
          onPressed: () => setState(() => showLog = !showLog),
          child: Text(
            showLog ? 'Hide technical log' : 'Show technical log',
            style: SyrenText.mono.copyWith(
              fontSize: 12,
              decoration: TextDecoration.underline,
              decorationColor: SyrenColors.muted,
            ),
          ),
        ),
      ),
      if (showLog)
        SyrenCard(
          color: SyrenColors.softCard,
          child: SelectableText(
            [
              for (final speaker in room.speakers)
                '${speaker.name} (${speaker.id})\n${speaker.status == null ? 'No report received' : const JsonEncoder.withIndent('  ').convert(speaker.status)}',
            ].join('\n\n'),
            style: SyrenText.mono.copyWith(
              fontSize: 11,
              color: SyrenColors.ink,
            ),
          ),
        ),
    ];
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.room});

  final Room room;

  @override
  Widget build(BuildContext context) {
    return SyrenCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Playing now',
            style: SyrenText.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          for (final session in room.audible)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  PersonAvatar(session.owner, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(session.label, style: SyrenText.label),
                        Text(
                          session.destination == 'house'
                              ? 'Sent to the whole house'
                              : 'Sent to this room',
                          style: SyrenText.small,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (room.audible.length > 1)
            Text('These sources are mixed.', style: SyrenText.small),
        ],
      ),
    );
  }
}

/// The path audio takes to a room. The first failing step is the answer.
class _Trace extends StatelessWidget {
  const _Trace({required this.room});

  final Room room;

  @override
  Widget build(BuildContext context) {
    return SyrenCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "Why it's quiet",
            style: SyrenText.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          for (final (index, step) in room.trace.indexed)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      _StepMark(step.state),
                      if (index < room.trace.length - 1)
                        Expanded(
                          child: Container(
                            width: 2,
                            constraints: const BoxConstraints(minHeight: 18),
                            color: SyrenColors.border,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: index < room.trace.length - 1 ? 14 : 0,
                        top: 2,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            step.title,
                            style: SyrenText.label.copyWith(
                              color: step.state == TraceState.waiting
                                  ? SyrenColors.faint
                                  : SyrenColors.ink,
                            ),
                          ),
                          if (step.detail.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(step.detail, style: SyrenText.small),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StepMark extends StatelessWidget {
  const _StepMark(this.state);

  final TraceState state;

  @override
  Widget build(BuildContext context) {
    final (mark, background, foreground) = switch (state) {
      TraceState.done => (
        Icons.check,
        SyrenColors.goodBackground,
        SyrenColors.good,
      ),
      TraceState.failed => (
        Icons.close,
        SyrenColors.badBackground,
        SyrenColors.bad,
      ),
      TraceState.waiting => (null, SyrenColors.divider, SyrenColors.faint),
    };
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: mark == null ? null : Icon(mark, size: 14, color: foreground),
    );
  }
}
