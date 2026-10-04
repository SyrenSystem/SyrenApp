import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/household.dart';
import '../../providers/settings_provider.dart';
import '../../util/app_version.dart';
import '../app_feedback.dart';
import '../syren_theme.dart';
import 'profile_shell.dart';
import 'syren_widgets.dart';

/// Speakers, positioning and the hub connection.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.profile});

  final ProfileContext profile;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> with CommandRunner {
  bool showReports = false;
  late final Future<String> version = loadAppVersion();

  @override
  Widget build(BuildContext context) {
    final controller = widget.profile.controller;
    final positioning = widget.profile.positioning;
    return HouseholdBuilder(
      controller: controller,
      builder: (context, household) {
        final measuring = positioning.isMeasuring();
        return Scaffold(
          body: SyrenPage(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
            children: [
              const BackLink('Home'),
              const PageHeader(title: 'Setup'),
              RowsCard(
                rows: [
                  InfoRow(
                    label: 'Hub',
                    value: controller.mqtt.isConnected
                        ? controller.mqtt.connectedHost ?? 'Connected'
                        : 'Not connected',
                    valueColor: controller.mqtt.isConnected
                        ? null
                        : SyrenColors.bad,
                  ),
                  InfoRow(
                    label: 'Syren server',
                    value: controller.serverOnline ? 'Running' : 'Offline',
                    valueColor: controller.serverOnline
                        ? SyrenColors.good
                        : SyrenColors.bad,
                  ),
                  InfoRow(
                    label: 'Playback',
                    value: household.activated
                        ? 'Switched on'
                        : 'Waiting for activation',
                    valueColor: household.activated
                        ? SyrenColors.good
                        : SyrenColors.warning,
                  ),
                  if (controller.error != null)
                    InfoRow(
                      label: 'Last problem',
                      value: friendlyError(controller.error!),
                      valueColor: SyrenColors.bad,
                    ),
                ],
              ),
              const MonoLabel('Speakers'),
              if (household.speakers.isEmpty)
                const NoteBox('No speakers are set up on the hub yet.')
              else
                RowsCard(
                  rows: [
                    for (final speaker in household.speakers)
                      InfoRow(
                        label: speaker.name,
                        bold: true,
                        value: '${speaker.online ? 'Online' : 'Offline'} ›',
                        valueColor: speaker.online ? null : SyrenColors.warning,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => SpeakerPage(
                              profile: widget.profile,
                              speakerId: speaker.id,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              const MonoLabel('Positioning'),
              SyrenCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Distance sensor on this device',
                            style: SyrenText.label,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            measuring
                                ? 'Measuring and sending readings'
                                : 'Not measuring',
                            style: SyrenText.small,
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              await positioning.toggle();
                              if (mounted) setState(() {});
                            }),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: SyrenColors.ink,
                        side: const BorderSide(
                          color: SyrenColors.ink,
                          width: 1.5,
                        ),
                        shape: const StadiumBorder(),
                      ),
                      child: Text(measuring ? 'Stop' : 'Start'),
                    ),
                  ],
                ),
              ),
              const MonoLabel('Hub connection'),
              const HubAddressCard(),
              Center(
                child: TextButton(
                  onPressed: () => setState(() => showReports = !showReports),
                  child: Text(
                    showReports
                        ? 'Hide speaker reports'
                        : 'Show speaker reports',
                    style: SyrenText.mono.copyWith(
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                      decorationColor: SyrenColors.muted,
                    ),
                  ),
                ),
              ),
              if (showReports)
                SyrenCard(
                  color: SyrenColors.softCard,
                  child: SelectableText(
                    const JsonEncoder.withIndent(
                      '  ',
                    ).convert(controller.receivers),
                    style: SyrenText.mono.copyWith(
                      fontSize: 11,
                      color: SyrenColors.ink,
                    ),
                  ),
                ),
              FutureBuilder<String>(
                future: version,
                builder: (context, snapshot) => Text(
                  snapshot.data ?? 'Loading version…',
                  textAlign: TextAlign.center,
                  style: SyrenText.small,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Hub address and port, saved on this device.
class HubAddressCard extends ConsumerStatefulWidget {
  const HubAddressCard({super.key, this.buttonLabel = 'Save'});

  final String buttonLabel;

  @override
  ConsumerState<HubAddressCard> createState() => _HubAddressCardState();
}

class _HubAddressCardState extends ConsumerState<HubAddressCard> {
  final address = TextEditingController();
  final port = TextEditingController();
  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    address.text = settings.ip;
    port.text = '${settings.port}';
    // Settings load after start, so fields fill in unless someone already typed.
    ref.listenManual(settingsProvider, (previous, next) {
      if (address.text.isEmpty || address.text == previous?.ip) {
        address.text = next.ip;
      }
      if (port.text == '${previous?.port}') port.text = '${next.port}';
    });
  }

  @override
  void dispose() {
    address.dispose();
    port.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final host = address.text.trim();
    final number = int.tryParse(port.text.trim());
    if (host.isEmpty || number == null || number <= 0 || number > 65535) {
      showLatestSnackBar(
        context,
        const SnackBar(
          content: Text('Enter the hub address and a port from 1 to 65535'),
        ),
      );
      return;
    }
    await ref.read(settingsProvider.notifier).saveSettings(host, number);
    if (mounted) FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    const fieldStyle = TextStyle(
      fontFamily: SyrenFonts.sans,
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: SyrenColors.ink,
    );
    return SyrenCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: address,
              style: fieldStyle,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: '192.168.1.100',
              ),
              onSubmitted: (_) => unawaited(save()),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 64,
            child: TextField(
              controller: port,
              style: fieldStyle,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
              onSubmitted: (_) => unawaited(save()),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: save,
            style: FilledButton.styleFrom(
              backgroundColor: SyrenColors.ink,
              foregroundColor: Colors.white,
              textStyle: const TextStyle(
                fontFamily: SyrenFonts.sans,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(widget.buttonLabel),
          ),
        ],
      ),
    );
  }
}

/// One speaker: its level, name and position sensor.
class SpeakerPage extends StatefulWidget {
  const SpeakerPage({
    super.key,
    required this.profile,
    required this.speakerId,
  });

  final ProfileContext profile;
  final String speakerId;

  @override
  State<SpeakerPage> createState() => _SpeakerPageState();
}

class _SpeakerPageState extends State<SpeakerPage> with CommandRunner {
  Map<String, TextEditingController>? fields;

  Map<String, TextEditingController> fieldsFor(SpeakerState speaker) =>
      fields ??= {
        'name': TextEditingController(text: speaker.name),
        'sensorId': TextEditingController(
          text: speaker.speaker['sensorId'] as String? ?? '',
        ),
        'fullVolumeDistance': TextEditingController(
          text: '${speaker.speaker['fullVolumeDistance']}',
        ),
        'muteDistance': TextEditingController(
          text: '${speaker.speaker['muteDistance']}',
        ),
      };

  @override
  void dispose() {
    for (final field in fields?.values ?? const <TextEditingController>[]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> save(SpeakerState speaker) async {
    final values = fields!;
    final full = double.tryParse(values['fullVolumeDistance']!.text.trim());
    final mute = double.tryParse(values['muteDistance']!.text.trim());
    if (values['name']!.text.trim().isEmpty || full == null || mute == null) {
      throw StateError('Enter a name and both distances in millimeters');
    }
    final sensor = values['sensorId']!.text.trim();
    await widget.profile.controller.command('speaker', {
      'speakerId': speaker.id,
      'snapClientId': speaker.speaker['snapClientId'],
      'name': values['name']!.text.trim(),
      'sensorId': sensor.isEmpty ? null : sensor,
      'fullVolumeDistance': full,
      'muteDistance': mute,
    });
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return HouseholdBuilder(
      controller: widget.profile.controller,
      builder: (context, household) {
        final speaker = household.speakers
            .where((speaker) => speaker.id == widget.speakerId)
            .firstOrNull;
        if (speaker == null) {
          return const Scaffold(
            body: SyrenPage(
              children: [
                BackLink('Setup'),
                Text('This speaker was removed', style: SyrenText.title),
              ],
            ),
          );
        }
        final values = fieldsFor(speaker);
        final room = household.rooms
            .where(
              (room) => room.speakers.any((member) => member.id == speaker.id),
            )
            .map((room) => room.name)
            .firstOrNull;
        Widget field(
          String key,
          String label, {
          bool number = false,
          String? hint,
        }) => TextField(
          controller: values[key],
          keyboardType: number ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
        );
        return Scaffold(
          body: SyrenPage(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
            children: [
              const BackLink('Setup'),
              PageHeader(
                title: speaker.name,
                subtitle: room == null ? 'Not in a room' : 'In $room',
                trailing: StatusChip(
                  speaker.online ? 'Online' : 'Offline',
                  background: speaker.online
                      ? SyrenColors.goodBackground
                      : SyrenColors.warningBackground,
                  foreground: speaker.online
                      ? SyrenColors.good
                      : SyrenColors.warning,
                ),
              ),
              SyrenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LevelSlider(
                      label: 'Level',
                      value: speaker.level,
                      onChanged: (value) => unawaited(
                        widget.profile.controller
                            .setVolume(speaker.id, value, speaker: true)
                            .catchError((Object error) {
                              if (context.mounted) {
                                showLatestSnackBar(
                                  context,
                                  SnackBar(content: Text(friendlyError(error))),
                                );
                              }
                            }),
                      ),
                    ),
                    Text(
                      'Balances this speaker against the others in its room.',
                      style: SyrenText.small,
                    ),
                  ],
                ),
              ),
              SyrenCard(
                child: Column(
                  children: [
                    field('name', 'Name'),
                    field('sensorId', 'Position sensor ID', hint: 'Optional'),
                    field(
                      'fullVolumeDistance',
                      'Full volume within (mm)',
                      number: true,
                    ),
                    field('muteDistance', 'Silent beyond (mm)', number: true),
                  ],
                ),
              ),
              const NoteBox(
                'The sensor and distances are only used by Follow me. Closer than the first distance plays at full volume, further than the second is silent.',
              ),
              SyrenButton(
                'Save speaker',
                onPressed: busy ? null : () => run(() => save(speaker)),
              ),
            ],
          ),
        );
      },
    );
  }
}
