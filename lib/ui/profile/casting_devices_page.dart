import 'package:flutter/material.dart';

import '../../models/household.dart';
import '../syren_theme.dart';
import 'profile_shell.dart';
import 'syren_widgets.dart';

/// Explains how AirPlay finds SyrenSystem, then links devices that played here.
class CastingDevicesPage extends StatefulWidget {
  const CastingDevicesPage({super.key, required this.profile});

  final ProfileContext profile;

  @override
  State<CastingDevicesPage> createState() => _CastingDevicesPageState();
}

class _CastingDevicesPageState extends State<CastingDevicesPage>
    with CommandRunner {
  static const _steps = [
    'Pick SyrenSystem or SyrenSystem · room in Control Center and play',
    'Your device appears below for 15 minutes after it played here',
    'Link it so it plays with your rules',
  ];

  static List<Map<String, dynamic>> _devices(Object? value) => [
    for (final device in (value is List ? value : const []))
      if (device is Map<String, dynamic> && device['id'] is String) device,
  ];

  @override
  Widget build(BuildContext context) {
    final controller = widget.profile.controller;
    return HouseholdBuilder(
      controller: controller,
      builder: (context, household) {
        final me = household.person(controller.selectedId);
        if (me == null) return const Scaffold();
        final linked = _devices(me.profile!['castingDevices']);
        final owners = {
          for (final person in household.people)
            for (final device in _devices(person.profile?['castingDevices']))
              device['id'] as String: person,
        };
        final seen = _devices(controller.castingDevices?['devices']);
        final seenById = {
          for (final device in seen) device['id'] as String: device,
        };
        Person? ownerOf(Map<String, dynamic> device) =>
            owners[device['id']] ??
            household.person(device['profileId'] as String?);
        final recent = [
          for (final device in seen)
            if (ownerOf(device)?.id != me.id) device,
        ];
        void command(String action, Map<String, dynamic> fields) =>
            run(() => controller.command(action, fields));
        return Scaffold(
          body: SyrenPage(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            spacing: 22,
            children: [
              const BackLink('Me'),
              Text(
                linked.isEmpty
                    ? 'Link your AirPlay device, ${me.name}'
                    : 'Your AirPlay devices, ${me.name}',
                style: SyrenText.hero,
              ),
              RowsCard(
                rows: [
                  for (final (index, step) in _steps.indexed)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '0${index + 1}',
                            style: SyrenText.mono.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: SyrenColors.accent,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(child: Text(step, style: SyrenText.body)),
                        ],
                      ),
                    ),
                ],
              ),
              if (linked.isNotEmpty) ...[
                const MonoLabel('Linked'),
                RowsCard(
                  rows: [
                    for (final device in linked)
                      _DeviceRow(
                        name: device['name'] as String? ?? 'AirPlay device',
                        detail: seenById[device['id']] == null
                            ? 'Plays with your rules'
                            : _seen(seenById[device['id']]!),
                        actions: [
                          SyrenButton(
                            'Unlink',
                            kind: ButtonKind.link,
                            onPressed: busy
                                ? null
                                : () => command('unlinkCasting', {
                                    'profileId': me.id,
                                    'deviceId': device['id'],
                                  }),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
              if (seen.isEmpty || recent.isNotEmpty)
                const MonoLabel('Recently seen'),
              if (seen.isEmpty)
                const NoteBox(
                  'No AirPlay device has played here in the last 15 minutes.',
                ),
              if (recent.isNotEmpty)
                RowsCard(
                  rows: [
                    for (final device in recent)
                      if (ownerOf(device) case final other?)
                        _DeviceRow(
                          name: device['name'] as String? ?? 'AirPlay device',
                          detail: 'Linked to ${other.name}',
                        )
                      else
                        _DeviceRow(
                          name: device['name'] as String? ?? 'AirPlay device',
                          detail: _seen(device),
                          actions: [
                            SyrenButton(
                              'Forget',
                              kind: ButtonKind.link,
                              onPressed: busy
                                  ? null
                                  : () => command('forgetCasting', {
                                      'deviceId': device['id'],
                                    }),
                            ),
                            SyrenButton(
                              'Link',
                              onPressed: busy
                                  ? null
                                  : () => command('linkCasting', {
                                      'profileId': me.id,
                                      'deviceId': device['id'],
                                    }),
                            ),
                          ],
                        ),
                  ],
                ),
              const Text(
                'Names of devices that are not linked are never stored.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: SyrenFonts.sans,
                  fontSize: 12,
                  color: SyrenColors.muted,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// When the server last saw a device, in a few words.
String _seen(Map<String, dynamic> device) {
  if (device['playing'] == true) return 'Playing now';
  if (device['connected'] == true) return 'Connected now';
  final lastSeen = DateTime.tryParse('${device['lastSeen']}');
  if (lastSeen == null) return 'Seen recently';
  final minutes = DateTime.now().difference(lastSeen).inMinutes;
  if (minutes < 1) return 'Seen just now';
  if (minutes < 60) return 'Seen $minutes min ago';
  return 'Seen ${minutes ~/ 60} h ago';
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.name,
    required this.detail,
    this.actions = const [],
  });

  final String name;
  final String detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: SyrenText.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(detail, style: SyrenText.small),
              ],
            ),
          ),
          for (final action in actions) ...[const SizedBox(width: 6), action],
        ],
      ),
    );
  }
}
