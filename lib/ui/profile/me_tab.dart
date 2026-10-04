import 'package:flutter/material.dart';

import '../../models/household.dart';
import '../syren_theme.dart';
import 'profile_picker.dart';
import 'profile_shell.dart';
import 'syren_widgets.dart';

/// My profile: what I am playing, Spotify, Follow me and PC audio.
class MeTab extends StatefulWidget {
  const MeTab({
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
  State<MeTab> createState() => _MeTabState();
}

class _MeTabState extends State<MeTab> with CommandRunner {
  void push(Widget page) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (context) => page));
  }

  Future<void> rename() async {
    final name = await askName(context, 'Rename profile', widget.me.name);
    if (name != null) {
      await widget.profile.controller.saveProfile({
        ...widget.me.profile!,
        'name': name,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.profile.controller;
    final me = widget.me;
    final linked = me.profile!['spotifyAccountId'] != null;
    return SyrenPage(
      children: [
        PageHeader(title: 'Me', trailing: widget.avatar),
        ListeningCard(household: widget.household, me: me),
        RowsCard(
          rows: [
            InfoRow(
              label: 'Spotify',
              value: linked ? 'Linked ›' : 'Not linked ›',
              valueColor: linked ? SyrenColors.good : null,
              onTap: () => push(SpotifyLinkPage(profile: widget.profile)),
            ),
            InfoRow(
              label: 'Follow me',
              value: me.followMe ? 'On ›' : 'Off ›',
              onTap: () => push(FollowMePage(profile: widget.profile)),
            ),
            InfoRow(
              label: 'Name',
              value: '${me.name} ›',
              onTap: busy ? null : () => run(rename),
            ),
          ],
        ),
        if (controller.pcAvailable) PcAudioCard(profile: widget.profile),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            linked
                ? 'Pick SyrenSystem or SyrenSystem · room in Spotify. This app can be closed while Spotify plays.'
                : 'Link Spotify to play music from your own account.',
            style: SyrenText.small,
          ),
        ),
      ],
    );
  }
}

/// My sessions in my color, with the rooms that hear them.
class ListeningCard extends StatelessWidget {
  const ListeningCard({super.key, required this.household, required this.me});

  final Household household;
  final Person me;

  @override
  Widget build(BuildContext context) {
    final color = personColor(me);
    final sessions = household.sessionsOf(me.id);
    const white = Colors.white;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sessions.isEmpty
                      ? 'YOU'
                      : 'YOU · ${sessions.map((session) => sourceName(session.source).toUpperCase()).toSet().join(' + ')}',
                  style: const TextStyle(
                    fontFamily: SyrenFonts.sans,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: white,
                  ),
                ),
              ),
              if (me.followMe)
                const Text(
                  'Follow me on',
                  style: TextStyle(
                    fontFamily: SyrenFonts.sans,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: white,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (sessions.isEmpty) ...[
            const Text(
              'Nothing playing',
              style: TextStyle(
                fontFamily: SyrenFonts.sans,
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: white,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'Start something in Spotify and pick SyrenSystem.',
              style: TextStyle(
                fontFamily: SyrenFonts.sans,
                fontSize: 15,
                color: white,
              ),
            ),
          ],
          for (final session in sessions) ...[
            Text(
              sourceName(session.source),
              style: const TextStyle(
                fontFamily: SyrenFonts.sans,
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: white,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final room in household.roomsHearing(session))
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${room.name} · ${room.volume.round()}',
                      style: TextStyle(
                        fontFamily: SyrenFonts.sans,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: SyrenColors.shade(color),
                      ),
                    ),
                  ),
                if (household.roomsHearing(session).isEmpty)
                  Text(
                    session.eligible
                        ? 'Not heard in any room right now'
                        : 'Paused',
                    style: const TextStyle(
                      fontFamily: SyrenFonts.sans,
                      fontSize: 14,
                      color: white,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// Follow me and the position readings it depends on.
class FollowMePage extends StatefulWidget {
  const FollowMePage({super.key, required this.profile});

  final ProfileContext profile;

  @override
  State<FollowMePage> createState() => _FollowMePageState();
}

class _FollowMePageState extends State<FollowMePage> with CommandRunner {
  @override
  Widget build(BuildContext context) {
    final controller = widget.profile.controller;
    final positioning = widget.profile.positioning;
    return HouseholdBuilder(
      controller: controller,
      builder: (context, household) {
        final me = household.person(controller.selectedId);
        if (me == null) return const Scaffold();
        final color = personColor(me);
        final reporting = controller.lease != null;
        final measuring = positioning.isMeasuring();
        final sensed = household.speakers
            .where((speaker) => speaker.speaker['sensorId'] != null)
            .toList();
        final signal = !reporting
            ? 'Another app, or none, reports where you are'
            : measuring
            ? 'Located via this device'
            : 'This app reports your position, but the sensor is off';
        return Scaffold(
          body: SyrenPage(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
            spacing: 12,
            children: [
              const BackLink('Me'),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Follow me',
                            style: TextStyle(
                              fontFamily: SyrenFonts.sans,
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Switch(
                          value: me.followMe,
                          thumbColor: WidgetStatePropertyAll(
                            me.followMe ? color : Colors.white,
                          ),
                          trackColor: WidgetStatePropertyAll(
                            me.followMe
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.35),
                          ),
                          onChanged: busy
                              ? null
                              : (value) => run(
                                  () => controller.saveProfile({
                                    ...me.profile!,
                                    'followMe': value,
                                  }),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Your music plays louder in the rooms you are close to, and goes quiet where you are not.',
                      style: TextStyle(
                        fontFamily: SyrenFonts.sans,
                        fontSize: 15,
                        height: 1.4,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      signal,
                      style: const TextStyle(
                        fontFamily: SyrenFonts.sans,
                        fontSize: 12,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              RowsCard(
                rows: [
                  _ActionRow(
                    title: 'Report my position from this app',
                    subtitle: reporting
                        ? 'This app has the job'
                        : 'Takes over from any other app',
                    action: reporting ? null : 'Use this app',
                    onPressed: busy
                        ? null
                        : () => run(() => controller.select(me.id)),
                  ),
                  _ActionRow(
                    title: 'Distance sensor',
                    subtitle: measuring ? 'Measuring' : 'Not measuring',
                    action: measuring ? 'Stop' : 'Start',
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            await positioning.toggle();
                            if (mounted) setState(() {});
                          }),
                  ),
                ],
              ),
              NoteBox(
                sensed.isEmpty
                    ? 'No speaker has a position sensor yet, so Follow me would silence your music everywhere. Add sensors in Setup first.'
                    : '${sensed.length} of ${household.speakers.length} speakers have a position sensor. Speakers without a fresh reading go quiet for you while Follow me is on.',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.title,
    required this.subtitle,
    required this.action,
    required this.onPressed,
  });

  final String title;
  final String subtitle;
  final String? action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: SyrenText.label),
                const SizedBox(height: 2),
                Text(subtitle, style: SyrenText.small),
              ],
            ),
          ),
          if (action != null)
            OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: SyrenColors.ink,
                side: const BorderSide(color: SyrenColors.ink, width: 1.5),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontFamily: SyrenFonts.sans,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(action!),
            ),
        ],
      ),
    );
  }
}

/// Sends this computer's sound to the speakers. Linux only.
class PcAudioCard extends StatefulWidget {
  const PcAudioCard({super.key, required this.profile});

  final ProfileContext profile;

  @override
  State<PcAudioCard> createState() => _PcAudioCardState();
}

class _PcAudioCardState extends State<PcAudioCard> with CommandRunner {
  String destination = 'house';
  String? lowLatencySpeaker;
  final receiverAddress = TextEditingController();

  /// The address found for the chosen speaker, shown instead of the text field.
  String? knownAddress;
  bool editingAddress = false;

  @override
  void initState() {
    super.initState();
    destination = widget.profile.controller.preferredPcDestination;
    final speaker = widget.profile.controller.preferredPcSpeaker;
    if (speaker != null) chooseSpeaker(speaker);
  }

  Future<void> chooseSpeaker(String? speakerId) async {
    setState(() {
      lowLatencySpeaker = speakerId;
      knownAddress = null;
      editingAddress = false;
      receiverAddress.clear();
    });
    final remembering = widget.profile.controller.rememberPcSpeaker(speakerId);
    if (speakerId == null) {
      await remembering;
      return;
    }
    final found = await widget.profile.controller.knownSpeakerAddress(
      speakerId,
    );
    if (mounted && lowLatencySpeaker == speakerId && found != null) {
      setState(() {
        knownAddress = found;
        receiverAddress.text = found;
      });
    }
    await remembering;
  }

  @override
  void dispose() {
    receiverAddress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.profile.controller,
    builder: (context, _) => buildCard(context),
  );

  Widget buildCard(BuildContext context) {
    final controller = widget.profile.controller;
    final configuration = controller.configuration!;
    final running = controller.pcSessionId != null;
    final mode =
        controller.pcCaptureStatus?['mode'] as String? ??
        controller.preferredPcMode;
    final activeModes =
        (controller.pcCaptureStatus?['activeModes'] as List? ?? const [])
            .cast<String>();
    const labels = {'auto': 'Automatic', 'stable': 'Stable', 'fast': 'Fast'};
    final rooms = controller.groups
        .where((group) => (group['enabledSources'] as List).contains('laptop'))
        .toList();
    final speakers = (configuration['speakers'] as List)
        .cast<Map<String, dynamic>>();
    if (destination != 'house' &&
        !rooms.any((group) => group['id'] == destination)) {
      destination = 'house';
    }
    if (!speakers.any((speaker) => speaker['id'] == lowLatencySpeaker)) {
      lowLatencySpeaker = null;
    }
    return SyrenCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'PC audio from this computer',
                  style: SyrenText.cardTitle,
                ),
              ),
              if (running)
                const StatusChip(
                  'On',
                  background: SyrenColors.goodBackground,
                  foreground: SyrenColors.good,
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Keep this app open while it plays. Switching profiles does not move it.',
            style: SyrenText.small,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            // A new key resets the field when its choice falls back to the whole house.
            key: ValueKey('destination $destination'),
            initialValue: destination,
            decoration: const InputDecoration(labelText: 'Play in'),
            items: [
              const DropdownMenuItem(
                value: 'house',
                child: Text('Whole house'),
              ),
              for (final group in rooms)
                DropdownMenuItem(
                  value: group['id'] as String,
                  child: Text(group['name'] as String),
                ),
            ],
            onChanged: running
                ? null
                : (value) => setState(() => destination = value!),
          ),
          const SizedBox(height: 8),
          const Text('Output mode', style: SyrenText.small),
          const SizedBox(height: 6),
          SegmentedChoice<String>(
            options: labels,
            value: mode,
            onChanged: busy
                ? null
                : (value) => run(() => controller.setPcMode(value)),
          ),
          const SizedBox(height: 8),
          Text(switch (mode) {
            'stable' =>
              'Snapcast only. Uses the synchronized, buffered stream.',
            'fast' => 'RTP only on the fast speaker. No Snapcast fallback.',
            _ =>
              'Low latency on the fast speaker when healthy, with Snapcast fallback.',
          }, style: SyrenText.small),
          if (running) ...[
            const SizedBox(height: 8),
            if (controller.pcCaptureStatus?['mode'] == null &&
                controller.pcCaptureStatus != null)
              const Text(
                'The desktop default output is outside SyrenSystem.',
                style: SyrenText.small,
              ),
            for (final playingMode
                in activeModes.isEmpty ? [mode] : activeModes)
              Text(
                '${labels[playingMode]}: ${controller.pcTransportDescription(playingMode)}',
                style: SyrenText.small,
              ),
          ],
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: ValueKey('speaker $lowLatencySpeaker'),
            initialValue: lowLatencySpeaker,
            decoration: const InputDecoration(
              labelText: 'Fast speaker (optional for Automatic and Stable)',
            ),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('None')),
              for (final speaker in speakers)
                DropdownMenuItem<String?>(
                  value: speaker['id'] as String,
                  child: Text(speaker['name'] as String),
                ),
            ],
            onChanged: running ? null : chooseSpeaker,
          ),
          if (running)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Mode changes are live. Stop PC audio to change its destination or fast speaker.',
                style: SyrenText.small,
              ),
            ),
          if (lowLatencySpeaker != null &&
              knownAddress != null &&
              !editingAddress)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Sends to $knownAddress',
                      style: SyrenText.small.copyWith(fontSize: 14),
                    ),
                  ),
                  if (!running)
                    TextButton(
                      onPressed: () => setState(() => editingAddress = true),
                      child: const Text('Change'),
                    ),
                ],
              ),
            )
          else if (lowLatencySpeaker != null)
            TextField(
              controller: receiverAddress,
              enabled: !running,
              decoration: const InputDecoration(
                labelText: 'Speaker IPv4 address or name',
                contentPadding: EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          const SizedBox(height: 14),
          const Text(
            'Desktop outputs: SyrenSystem (automatic), SyrenSystem_stable, SyrenSystem_fast. You can also choose them in your OS sound settings.',
            style: SyrenText.small,
          ),
          const SizedBox(height: 12),
          SyrenButton(
            running ? 'Stop PC audio' : 'Play PC audio',
            kind: running ? ButtonKind.outline : ButtonKind.primary,
            onPressed: busy
                ? null
                : () => run(() async {
                    if (running) {
                      await controller.stopPc();
                    } else {
                      await controller.startPc(
                        destination,
                        speakerId: lowLatencySpeaker,
                        receiverAddress: lowLatencySpeaker == null
                            ? null
                            : receiverAddress.text.trim(),
                      );
                    }
                  }),
          ),
        ],
      ),
    );
  }
}
