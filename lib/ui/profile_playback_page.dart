import 'dart:async';

import 'package:flutter/material.dart';
import '../services/profile_session_controller.dart';
import 'settings_page_widget.dart';

const sourceNames = {
  'spotify': 'Spotify',
  'laptop': 'PC audio',
  'casting': 'Casting (future)',
};

class ProfilePlaybackPage extends StatefulWidget {
  const ProfilePlaybackPage({
    super.key,
    required this.controller,
    required this.onMeasurement,
  });
  final ProfileSessionController controller;
  final VoidCallback onMeasurement;

  @override
  State<ProfilePlaybackPage> createState() => _ProfilePlaybackPageState();
}

class _ProfilePlaybackPageState extends State<ProfilePlaybackPage> {
  bool busy = false;
  String destination = 'house';
  String? lowLatencySpeaker;
  final receiverAddress = TextEditingController();
  ProfileSessionController get controller => widget.controller;

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> nameDialog(String title, [String initial = '']) async {
    final field = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 100,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (field.text.trim().isNotEmpty) {
                Navigator.pop(context, field.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    return result;
  }

  Future<void> editGroup([Map<String, dynamic>? existing]) async {
    final name = TextEditingController(
      text: existing?['name'] as String? ?? '',
    );
    final speakers = (controller.configuration!['speakers'] as List)
        .cast<Map<String, dynamic>>();
    final members = Set<String>.from(existing?['speakerIds'] as List? ?? []);
    final enabled = Set<String>.from(
      existing?['enabledSources'] as List? ?? ['spotify', 'laptop'],
    );
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Playback group'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Name'),
                    maxLength: 100,
                  ),
                  ...speakers.map(
                    (speaker) => CheckboxListTile(
                      title: Text(speaker['name'] as String),
                      value: members.contains(speaker['id']),
                      onChanged: (value) => setDialogState(() {
                        if (value!) {
                          members.add(speaker['id'] as String);
                        } else {
                          members.remove(speaker['id']);
                        }
                      }),
                    ),
                  ),
                  ...['spotify', 'laptop'].map(
                    (source) => CheckboxListTile(
                      title: Text(sourceNames[source]!),
                      value: enabled.contains(source),
                      onChanged: (value) => setDialogState(() {
                        if (value!) {
                          enabled.add(source);
                        } else {
                          enabled.remove(source);
                        }
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isNotEmpty) {
                  Navigator.pop(context, {
                    'groupId': existing?['id'],
                    'name': name.text.trim(),
                    'speakerIds': members.toList(),
                    'enabledSources': enabled.toList(),
                    'sourceLevels':
                        existing?['sourceLevels'] ??
                        {'spotify': 100.0, 'laptop': 100.0},
                    'masterVolume': existing?['masterVolume'] ?? 100.0,
                    'muted': existing?['muted'] ?? false,
                  });
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    if (result != null) await controller.command('group', result);
  }

  Future<void> editSpeaker(Map<String, dynamic> speaker) async {
    final fields = {
      'name': TextEditingController(text: speaker['name'] as String),
      'sensorId': TextEditingController(
        text: speaker['sensorId'] as String? ?? '',
      ),
      'fullVolumeDistance': TextEditingController(
        text: '${speaker['fullVolumeDistance']}',
      ),
      'muteDistance': TextEditingController(text: '${speaker['muteDistance']}'),
    };
    final labels = {
      'name': 'Speaker name',
      'sensorId': 'Position sensor ID (optional)',
      'fullVolumeDistance': 'Full volume distance (mm)',
      'muteDistance': 'Mute distance (mm)',
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Speaker settings'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in fields.entries)
                TextField(
                  controller: entry.value,
                  decoration: InputDecoration(labelText: labels[entry.key]),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    try {
      if (saved == true) {
        await controller.command('speaker', {
          'speakerId': speaker['id'],
          'snapClientId': speaker['snapClientId'],
          'name': fields['name']!.text.trim(),
          'sensorId': fields['sensorId']!.text.trim().isEmpty
              ? null
              : fields['sensorId']!.text.trim(),
          'fullVolumeDistance': double.parse(
            fields['fullVolumeDistance']!.text,
          ),
          'muteDistance': double.parse(fields['muteDistance']!.text),
        });
      }
    } finally {
      for (final field in fields.values) {
        field.dispose();
      }
    }
  }

  void volume(
    String identity,
    double value, {
    String? source,
    bool speaker = false,
  }) {
    unawaited(
      controller
          .setVolume(identity, value, source: source, speaker: speaker)
          .catchError((Object error) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(error.toString())));
            }
          }),
    );
  }

  Future<void> changeGroup(
    Map<String, dynamic> group,
    Map<String, dynamic> change,
  ) async {
    await controller.command('group', {
      ...group,
      'groupId': group['id'],
      ...change,
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = controller.selected;
    final configuration = controller.configuration!;
    final order = (selected?['sourcePriority'] as List? ?? []).cast<String>();
    final overlap = (selected?['overlap'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final sources = sourceNames.keys.toList();
    if (destination != 'house' &&
        !controller.groups.any(
          (group) =>
              group['id'] == destination &&
              (group['enabledSources'] as List).contains('laptop'),
        )) {
      destination = 'house';
    }
    if (!(configuration['speakers'] as List).any(
      (speaker) => speaker['id'] == lowLatencySpeaker,
    )) {
      lowLatencySpeaker = null;
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('SyrenSystem'),
        actions: [
          IconButton(
            tooltip: 'Connection settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  appBar: AppBar(title: const Text('Settings')),
                  body: const SettingsPageWidget(),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: widget.onMeasurement,
            tooltip: 'Start or stop positioning measurements',
            icon: const Icon(Icons.social_distance),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (selected == null) ...[
                Text(
                  'Who is listening?',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const Text(
                  'Choose a household profile or create one. New profiles prefer Spotify before PC audio. Follow me and all overlap pairs start off.',
                ),
              ],
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<String>(
                    value: selected?['id'] as String?,
                    hint: const Text('Choose profile'),
                    items: controller.profiles
                        .map(
                          (profile) => DropdownMenuItem(
                            value: profile['id'] as String,
                            child: Text(profile['name'] as String),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (value) => run(() => controller.select(value!)),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.person_add),
                    label: const Text('Create profile'),
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            final name = await nameDialog('Create profile');
                            if (name == null) return;
                            final identity =
                                '${controller.instanceId}-${DateTime.now().microsecondsSinceEpoch}';
                            await controller.saveProfile({
                              'id': identity,
                              'name': name,
                              'followMe': false,
                              'sourcePriority': [
                                'spotify',
                                'laptop',
                                'casting',
                              ],
                              'overlap': <Object>[],
                            });
                            await controller.select(identity);
                          }),
                  ),
                  if (selected != null)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              final name = await nameDialog(
                                'Rename profile',
                                selected['name'] as String,
                              );
                              if (name != null) {
                                await controller.saveProfile({
                                  ...selected,
                                  'name': name,
                                });
                              }
                            }),
                      child: const Text('Rename'),
                    ),
                ],
              ),
              // One fixed child, so status lines never shift the tiles below and reset their expansion.
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (busy) const LinearProgressIndicator(),
                  if (!controller.serverOnline)
                    ListTile(
                      leading: Icon(
                        Icons.cloud_off,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: const Text('The server is offline'),
                      subtitle: const Text(
                        'Settings below may be out of date. Changes are possible again when the server returns.',
                      ),
                    ),
                  if (controller.error != null)
                    Text(
                      controller.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
              if (selected != null) ...[
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => run(
                          () => controller.select(selected['id'] as String),
                        ),
                  icon: const Icon(Icons.my_location),
                  label: const Text('Use this app for positioning'),
                ),
                SwitchListTile(
                  title: const Text('Follow me'),
                  subtitle: const Text(
                    'Uses this profile’s current position. Speakers become silent for this profile when readings expire.',
                  ),
                  value: selected['followMe'] as bool,
                  onChanged: busy
                      ? null
                      : (value) => run(
                          () => controller.saveProfile({
                            ...selected,
                            'followMe': value,
                          }),
                        ),
                ),
                ListTile(
                  title: const Text('Spotify account'),
                  subtitle: Text(
                    selected['spotifyAccountId'] == null
                        ? 'Not linked'
                        : 'Linked to this profile',
                  ),
                  trailing: TextButton(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            if (selected['spotifyAccountId'] == null) {
                              await controller.linkSpotify();
                            } else {
                              await controller.command('unlink', {
                                'profileId': selected['id'],
                              });
                            }
                          }),
                    child: Text(
                      selected['spotifyAccountId'] == null
                          ? 'Link Spotify'
                          : 'Unlink',
                    ),
                  ),
                ),
                if (controller.linkStatus != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Spotify linking: ${controller.linkStatus!['status']}',
                        ),
                        if (controller.linkStatus!['error'] != null)
                          Text('${controller.linkStatus!['error']}'),
                        if (controller.linkStatus!['url'] != null)
                          SelectableText(
                            'Open ${controller.linkStatus!['url']} in the browser signed in to your Spotify account.',
                          ),
                      ],
                    ),
                  ),
                const Text(
                  'Select SyrenSystem or SyrenSystem · Group directly in Spotify. SyrenApp can be closed during Spotify playback.',
                ),
                ExpansionTile(
                  title: const Text('Source priority and overlap'),
                  initiallyExpanded: true,
                  children: [
                    ...order.asMap().entries.map(
                      (entry) => ListTile(
                        title: Text(
                          '${entry.key + 1}. ${sourceNames[entry.value]}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_upward),
                              onPressed: busy || entry.key == 0
                                  ? null
                                  : () => run(() async {
                                      final changed = List<String>.from(order);
                                      changed.removeAt(entry.key);
                                      changed.insert(
                                        entry.key - 1,
                                        entry.value,
                                      );
                                      await controller.saveProfile({
                                        ...selected,
                                        'sourcePriority': changed,
                                      });
                                    }),
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_downward),
                              onPressed: busy || entry.key == order.length - 1
                                  ? null
                                  : () => run(() async {
                                      final changed = List<String>.from(order);
                                      changed.removeAt(entry.key);
                                      changed.insert(
                                        entry.key + 1,
                                        entry.value,
                                      );
                                      await controller.saveProfile({
                                        ...selected,
                                        'sourcePriority': changed,
                                      });
                                    }),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Allow these sources to mix. Across people, both profiles must permit the pair. Otherwise the newer claim wins.',
                      ),
                    ),
                    for (var first = 0; first < sources.length; first++)
                      for (
                        var second = first;
                        second < sources.length;
                        second++
                      )
                        CheckboxListTile(
                          title: Text(
                            '${sourceNames[sources[first]]} + ${sourceNames[sources[second]]}',
                          ),
                          value: overlap.any(
                            (pair) =>
                                {pair['first'], pair['second']}.containsAll({
                                  sources[first],
                                  sources[second],
                                }) &&
                                {
                                  sources[first],
                                  sources[second],
                                }.containsAll({pair['first'], pair['second']}),
                          ),
                          onChanged: busy
                              ? null
                              : (enabled) => run(() async {
                                  final changed = overlap
                                      .where(
                                        (pair) =>
                                            !({
                                                  pair['first'],
                                                  pair['second'],
                                                }.containsAll({
                                                  sources[first],
                                                  sources[second],
                                                }) &&
                                                {
                                                  sources[first],
                                                  sources[second],
                                                }.containsAll({
                                                  pair['first'],
                                                  pair['second'],
                                                })),
                                      )
                                      .toList();
                                  if (enabled!) {
                                    changed.add({
                                      'first': sources[first],
                                      'second': sources[second],
                                    });
                                  }
                                  await controller.saveProfile({
                                    ...selected,
                                    'overlap': changed,
                                  });
                                }),
                        ),
                  ],
                ),
                ExpansionTile(
                  title: const Text(
                    'Source release policies (whole household)',
                  ),
                  children: [
                    // Always shows the server value, so a rejected or remote change is visible.
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Spotify keeps its claim',
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value:
                              (configuration['sourcePolicies']
                                      as Map)['spotify']
                                  as String,
                          isDense: true,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                              value: 'playing',
                              child: Text('While playing'),
                            ),
                            DropdownMenuItem(
                              value: 'connected',
                              child: Text('While the session is connected'),
                            ),
                          ],
                          onChanged: busy
                              ? null
                              : (value) => run(() async {
                                  await controller.command('policy', {
                                    'source': 'spotify',
                                    'policy': value,
                                  });
                                }),
                        ),
                      ),
                    ),
                    const ListTile(
                      title: Text('PC audio'),
                      subtitle: Text(
                        'Enabling claims, disabling or app failure releases. Silence keeps the claim.',
                      ),
                    ),
                    const ListTile(
                      title: Text('Future casting'),
                      subtitle: Text(
                        'Starting claims, ending releases. Pausing keeps the claim.',
                      ),
                    ),
                  ],
                ),
                ExpansionTile(
                  title: const Text('PC audio from this computer'),
                  children: [
                    const Text(
                      'This app must remain open. Switching profiles does not transfer a running PC session.',
                    ),
                    DropdownButton<String>(
                      value: destination,
                      items: [
                        const DropdownMenuItem(
                          value: 'house',
                          child: Text('SyrenSystem'),
                        ),
                        ...controller.groups
                            .where(
                              (group) => (group['enabledSources'] as List)
                                  .contains('laptop'),
                            )
                            .map(
                              (group) => DropdownMenuItem(
                                value: group['id'] as String,
                                child: Text('SyrenSystem · ${group['name']}'),
                              ),
                            ),
                      ],
                      onChanged: controller.pcSessionId != null
                          ? null
                          : (value) => setState(() => destination = value!),
                    ),
                    DropdownButton<String>(
                      value: lowLatencySpeaker,
                      hint: const Text('Optional low latency speaker'),
                      items: (configuration['speakers'] as List)
                          .map(
                            (speaker) => DropdownMenuItem(
                              value: speaker['id'] as String,
                              child: Text(speaker['name'] as String),
                            ),
                          )
                          .toList(),
                      onChanged: controller.pcSessionId != null
                          ? null
                          : (value) =>
                                setState(() => lowLatencySpeaker = value),
                    ),
                    if (lowLatencySpeaker != null)
                      TextField(
                        controller: receiverAddress,
                        decoration: const InputDecoration(
                          labelText: 'Speaker IPv4 address',
                        ),
                      ),
                    FilledButton(
                      onPressed: busy || !controller.pcAvailable
                          ? null
                          : () => run(() async {
                              if (controller.pcSessionId != null) {
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
                      child: Text(
                        controller.pcSessionId == null
                            ? 'Enable PC audio'
                            : 'Disable PC audio',
                      ),
                    ),
                  ],
                ),
                ListTile(
                  title: const Text('Playback groups'),
                  trailing: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: busy ? null : () => run(() => editGroup()),
                  ),
                ),
                ...controller.groups.map(
                  (group) => Card(
                    child: Column(
                      children: [
                        ListTile(
                          title: Text(group['name'] as String),
                          subtitle: Text(
                            (group['enabledSources'] as List)
                                .map((source) => sourceNames[source])
                                .join(', '),
                          ),
                          trailing: Wrap(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: busy
                                    ? null
                                    : () => run(() => editGroup(group)),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: busy
                                    ? null
                                    : () => run(() async {
                                        await controller.command(
                                          'deleteGroup',
                                          {'groupId': group['id']},
                                        );
                                      }),
                              ),
                            ],
                          ),
                        ),
                        SwitchListTile(
                          title: const Text('Mute'),
                          value: group['muted'] as bool,
                          onChanged: busy
                              ? null
                              : (value) => run(
                                  () => changeGroup(group, {'muted': value}),
                                ),
                        ),
                        _Level(
                          label: 'Group volume',
                          value: (group['masterVolume'] as num).toDouble(),
                          onChanged: (value) =>
                              volume(group['id'] as String, value),
                        ),
                        for (final source
                            in (group['enabledSources'] as List).cast<String>())
                          _Level(
                            label: sourceNames[source]!,
                            value:
                                ((group['sourceLevels'] as Map)[source]
                                            as num? ??
                                        100)
                                    .toDouble(),
                            onChanged: (value) => volume(
                              group['id'] as String,
                              value,
                              source: source,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const ListTile(title: Text('Speakers')),
                for (final speaker
                    in (configuration['speakers'] as List)
                        .cast<Map<String, dynamic>>())
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          title: Text(speaker['name'] as String),
                          subtitle: Text(
                            speaker['sensorId'] == null
                                ? 'No position sensor configured'
                                : 'Sensor: ${speaker['sensorId']}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: busy
                                ? null
                                : () => run(() => editSpeaker(speaker)),
                          ),
                        ),
                        _Level(
                          label: 'Speaker volume',
                          value: (speaker['level'] as num).toDouble(),
                          onChanged: (value) => volume(
                            speaker['id'] as String,
                            value,
                            speaker: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                const ListTile(title: Text('Reported speaker playback')),
                ...((controller.receivers?['receivers'] as List?) ?? []).map(
                  (receiver) => ListTile(
                    title: Text(
                      (configuration['speakers'] as List)
                              .where(
                                (speaker) =>
                                    speaker['id'] == receiver['speakerId'],
                              )
                              .map((speaker) => speaker['name'])
                              .firstOrNull
                              ?.toString() ??
                          receiver['speakerId'].toString(),
                    ),
                    subtitle: Text(
                      receiver['online'] == true
                          ? 'Audible: ${(receiver['status']['audible'] as List).map((identity) {
                              final session = (controller.catalogue?['sessions'] as List? ?? []).where((session) => session['id'] == identity).firstOrNull;
                              return session == null ? identity : '${sourceNames[session['source']]} (${controller.profiles.where((profile) => profile['id'] == session['ownerId']).map((profile) => profile['name']).firstOrNull ?? 'Guest'})';
                            }).join(', ')}\n${receiver['status']['reasons']}'
                          : 'Offline',
                    ),
                  ),
                ),
                if (configuration['playbackActivated'] != true)
                  const ListTile(
                    title: Text('Waiting for coordinated system activation'),
                    subtitle: Text(
                      'Playback starts after compatible server and speaker receivers have been installed.',
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    receiverAddress.dispose();
    super.dispose();
  }
}

class _Level extends StatefulWidget {
  const _Level({required this.label, required this.value, this.onChanged});
  final String label;
  final double value;
  final ValueChanged<double>? onChanged;
  @override
  State<_Level> createState() => _LevelState();
}

class _LevelState extends State<_Level> {
  double? dragging;
  @override
  Widget build(BuildContext context) => ListTile(
    title: Text('${widget.label}: ${(dragging ?? widget.value).round()}%'),
    subtitle: Slider(
      value: (dragging ?? widget.value).clamp(0, 100),
      max: 100,
      onChanged: widget.onChanged == null
          ? null
          : (value) {
              setState(() => dragging = value);
              widget.onChanged!(value);
            },
      onChangeEnd: widget.onChanged == null
          ? null
          : (value) {
              widget.onChanged!(value);
              setState(() => dragging = null);
            },
    ),
  );
}
