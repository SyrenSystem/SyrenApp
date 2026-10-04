import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/household.dart';
import '../app_feedback.dart';
import '../syren_theme.dart';
import 'profile_shell.dart';
import 'room_detail_page.dart';
import 'syren_widgets.dart';

/// What is playing where, and why the other rooms are silent.
class HomeTab extends StatelessWidget {
  const HomeTab({
    super.key,
    required this.profile,
    required this.household,
    required this.avatar,
    required this.onOpenRooms,
  });

  final ProfileContext profile;
  final Household household;
  final Widget avatar;
  final VoidCallback onOpenRooms;

  void openRoom(BuildContext context, Room room) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => RoomDetailPage(profile: profile, roomId: room.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rooms = household.rooms;
    final playing = rooms.where((room) => room.playing).toList();
    final silent = rooms.where((room) => !room.playing).toList();
    return SyrenPage(
      children: [
        PageHeader(
          title: 'Home',
          subtitle: rooms.isEmpty
              ? 'No rooms yet'
              : '${playing.length} of ${rooms.length} ${rooms.length == 1 ? 'room' : 'rooms'} playing',
          trailing: avatar,
        ),
        if (!household.activated)
          const NoteBox(
            'Playback starts once the hub and every speaker run the new receiver.',
          ),
        if (rooms.isEmpty)
          SyrenCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Make your first room', style: SyrenText.cardTitle),
                const SizedBox(height: 6),
                Text(
                  'A room is a set of speakers that play together. Spotify lists each one as a device.',
                  style: SyrenText.small,
                ),
                const SizedBox(height: 14),
                SyrenButton('Go to Rooms', onPressed: onOpenRooms),
              ],
            ),
          ),
        for (final room in playing)
          PlayingRoomCard(
            room: room,
            profile: profile,
            onTap: () => openRoom(context, room),
          ),
        if (silent.isNotEmpty || household.unassigned.isNotEmpty) ...[
          const MonoLabel('Silent · tap to see why'),
          RowsCard(
            color: SyrenColors.softCard,
            rows: [
              for (final room in silent)
                InfoRow(
                  label: room.name,
                  bold: true,
                  value: '${room.reason} ›',
                  valueColor: room.condition == RoomCondition.offline
                      ? SyrenColors.warning
                      : null,
                  onTap: () => openRoom(context, room),
                ),
              for (final speaker in household.unassigned)
                InfoRow(
                  label: speaker.name,
                  bold: true,
                  value: 'Not in a room ›',
                  onTap: onOpenRooms,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A playing room with who is playing, the room volume and a mute button.
class PlayingRoomCard extends StatelessWidget {
  const PlayingRoomCard({
    super.key,
    required this.room,
    required this.profile,
    required this.onTap,
  });

  final Room room;
  final ProfileContext profile;
  final VoidCallback onTap;

  void setVolume(BuildContext context, double value) {
    unawaited(
      profile.controller.setVolume(room.id, value).catchError((Object error) {
        if (context.mounted) {
          showLatestSnackBar(
            context,
            SnackBar(content: Text(friendlyError(error))),
          );
        }
      }),
    );
  }

  Future<void> mute(BuildContext context) async {
    try {
      await profile.controller.command('group', {
        ...room.group,
        'groupId': room.id,
        'muted': true,
      });
    } catch (error) {
      if (context.mounted) {
        showLatestSnackBar(
          context,
          SnackBar(content: Text(friendlyError(error))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final followers = room.audible.where((session) => session.owner.followMe);
    final color = room.audible.isEmpty
        ? SyrenColors.ink
        : personColor(room.audible.first.owner);
    return SyrenCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(room.name, style: SyrenText.cardTitle)),
              if (room.offlineCount > 0) ...[
                StatusChip(
                  '${room.offlineCount} offline',
                  background: SyrenColors.warningBackground,
                  foreground: SyrenColors.warning,
                ),
                const SizedBox(width: 6),
              ],
              if (followers.isNotEmpty)
                StatusChip(
                  'Follow me',
                  background: SyrenColors.tint(
                    personColor(followers.first.owner),
                  ),
                  foreground: SyrenColors.shade(
                    personColor(followers.first.owner),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          for (final session in room.audible)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  PersonAvatar(session.owner, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      session.owner.name,
                      overflow: TextOverflow.ellipsis,
                      style: SyrenText.body.copyWith(fontSize: 14),
                    ),
                  ),
                  Text(
                    sourceName(session.source),
                    style: SyrenText.small.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: LevelSlider(
                  value: room.volume,
                  color: color,
                  onChanged: (value) => setVolume(context, value),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Mute ${room.name}',
                style: IconButton.styleFrom(
                  backgroundColor: SyrenColors.background,
                  fixedSize: const Size(34, 34),
                  minimumSize: const Size(34, 34),
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(
                  Icons.volume_off_outlined,
                  size: 18,
                  color: SyrenColors.ink,
                ),
                onPressed: () => mute(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
