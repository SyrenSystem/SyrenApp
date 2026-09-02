import 'dart:async';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/ui/command_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PlaybackGroupsPage extends ConsumerWidget {
  const PlaybackGroupsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configuration = ref.watch(systemConfigurationProvider);
    return Container(
      color: const Color(0xFF0d121c),
      child: SafeArea(
        child: configuration == null
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
                    sliver: SliverToBoxAdapter(
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'PLAYBACK GROUPS',
                              style: TextStyle(
                                color: Color(0xFFd4af37),
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 3,
                              ),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: () =>
                                _editGroup(context, ref, configuration, null),
                            icon: const Icon(Icons.add),
                            label: const Text('Group'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (configuration.groups.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          'Create a group to start routing audio.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 120),
                      sliver: SliverList.separated(
                        itemCount: configuration.groups.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 16),
                        itemBuilder: (context, index) => _GroupCard(
                          key: ValueKey(configuration.groups[index].id),
                          configuration: configuration,
                          group: configuration.groups[index],
                          onEdit: () => _editGroup(
                            context,
                            ref,
                            configuration,
                            configuration.groups[index],
                          ),
                          onDelete: () => _deleteGroup(
                            context,
                            ref,
                            configuration,
                            configuration.groups[index],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _editGroup(
    BuildContext context,
    WidgetRef ref,
    SystemConfiguration configuration,
    PlaybackGroup? group,
  ) async {
    final draft = await showDialog<_GroupDraft>(
      context: context,
      builder: (context) =>
          _GroupEditor(configuration: configuration, group: group),
    );
    if (draft == null || !context.mounted) {
      return;
    }
    final result = await ref
        .read(mqttServiceProvider)
        .upsertGroup(
          // The revision from when the editor opened makes a concurrent edit fail instead of being overwritten.
          expectedRevision: configuration.revision,
          groupId: group?.id,
          name: draft.name,
          speakerIds: draft.speakerIds,
          sourcePriority: draft.sourcePriority,
          volumeMode: draft.automatic ? 'automatic' : 'manual',
          masterVolume: draft.masterVolume,
          muted: draft.muted,
        );
    if (context.mounted) {
      showCommandFeedback(context, result, 'Group saved');
    }
  }

  Future<void> _deleteGroup(
    BuildContext context,
    WidgetRef ref,
    SystemConfiguration configuration,
    PlaybackGroup group,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${group.name}?'),
        content: const Text('Its speakers will be muted until assigned again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final result = await ref
        .read(mqttServiceProvider)
        .deleteGroup(
          expectedRevision:
              ref.read(systemConfigurationProvider)?.revision ??
              configuration.revision,
          groupId: group.id,
        );
    if (context.mounted) {
      showCommandFeedback(context, result, 'Group deleted');
    }
  }
}

class _GroupCard extends ConsumerStatefulWidget {
  const _GroupCard({
    required this.configuration,
    required this.group,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  final SystemConfiguration configuration;
  final PlaybackGroup group;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  ConsumerState<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends ConsumerState<_GroupCard> {
  late double _masterVolume;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _masterVolume = widget.group.masterVolume;
  }

  @override
  void didUpdateWidget(covariant _GroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging) {
      _masterVolume = widget.group.masterVolume;
    }
  }

  @override
  Widget build(BuildContext context) {
    final speakersById = {
      for (final speaker in widget.configuration.speakers) speaker.id: speaker,
    };
    final sourceNames = {
      for (final source in widget.configuration.sources) source.id: source.name,
    };
    return Card(
      color: Colors.black.withValues(alpha: 0.28),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  widget.group.muted ? Icons.volume_off : Icons.speaker_group,
                  color: const Color(0xFFd4af37),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.group.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit),
                ),
                IconButton(
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text(
                    widget.group.automatic
                        ? 'Location volume'
                        : 'Manual volume',
                  ),
                ),
                for (
                  var index = 0;
                  index < widget.group.sourcePriority.length;
                  index++
                )
                  Chip(
                    avatar: CircleAvatar(child: Text('${index + 1}')),
                    label: Text(
                      sourceNames[widget.group.sourcePriority[index]] ??
                          widget.group.sourcePriority[index],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Master volume ${_masterVolume.round()}%',
              style: const TextStyle(color: Colors.white70),
            ),
            Slider(
              value: _masterVolume,
              max: 100,
              divisions: 100,
              onChangeStart: (_) => setState(() => _dragging = true),
              onChanged: (value) => setState(() => _masterVolume = value),
              onChangeEnd: (_) {
                setState(() => _dragging = false);
                unawaited(_saveMasterVolume());
              },
            ),
            const Divider(),
            for (final speakerId in widget.group.speakerIds)
              if (speakersById[speakerId] case final speaker?)
                _SpeakerLevelRow(
                  key: ValueKey(speaker.id),
                  speaker: speaker,
                  showUncalibratedHint:
                      widget.group.automatic && !speaker.calibrated,
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveMasterVolume() async {
    final latest = ref.read(systemConfigurationProvider);
    final group = latest?.groups
        .where((candidate) => candidate.id == widget.group.id)
        .firstOrNull;
    if (latest == null || group == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Group no longer exists')));
      }
      return;
    }
    final result = await ref
        .read(mqttServiceProvider)
        .upsertGroup(
          expectedRevision: latest.revision,
          groupId: group.id,
          name: group.name,
          speakerIds: group.speakerIds,
          sourcePriority: group.sourcePriority,
          volumeMode: group.volumeMode,
          masterVolume: _masterVolume,
          muted: group.muted,
        );
    if (mounted) {
      showCommandFeedback(context, result, 'Volume saved');
    }
  }
}

class _SpeakerLevelRow extends ConsumerStatefulWidget {
  const _SpeakerLevelRow({
    required this.speaker,
    required this.showUncalibratedHint,
    super.key,
  });

  final ConfiguredSpeaker speaker;
  final bool showUncalibratedHint;

  @override
  ConsumerState<_SpeakerLevelRow> createState() => _SpeakerLevelRowState();
}

class _SpeakerLevelRowState extends ConsumerState<_SpeakerLevelRow> {
  late double _level;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _level = widget.speaker.level;
  }

  @override
  void didUpdateWidget(covariant _SpeakerLevelRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging) {
      _level = widget.speaker.level;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(flex: 2, child: Text(widget.speaker.name)),
            Expanded(
              flex: 4,
              child: Slider(
                value: _level,
                max: 100,
                divisions: 100,
                onChangeStart: (_) => setState(() => _dragging = true),
                onChanged: (value) => setState(() => _level = value),
                onChangeEnd: (_) {
                  setState(() => _dragging = false);
                  unawaited(_save());
                },
              ),
            ),
            SizedBox(width: 44, child: Text('${_level.round()}%')),
          ],
        ),
        if (widget.showUncalibratedHint)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Uncalibrated, silent until calibrated',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Future<void> _save() async {
    final revision = ref.read(systemConfigurationProvider)?.revision;
    if (revision == null) {
      return;
    }
    final result = await ref
        .read(mqttServiceProvider)
        .setSpeakerLevel(
          expectedRevision: revision,
          speakerId: widget.speaker.id,
          level: _level,
        );
    if (mounted) {
      showCommandFeedback(context, result, 'Speaker level saved');
    }
  }
}

class _GroupEditor extends StatefulWidget {
  const _GroupEditor({required this.configuration, required this.group});

  final SystemConfiguration configuration;
  final PlaybackGroup? group;

  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<_GroupEditor> {
  late final TextEditingController _nameController;
  late final Set<String> _speakerIds;
  late final List<String> _sourcePriority;
  late bool _automatic;
  late bool _muted;
  late double _masterVolume;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.group?.name ?? 'New group',
    );
    _speakerIds = {...?widget.group?.speakerIds};
    _sourcePriority = [
      ...?widget.group?.sourcePriority,
      if (widget.group == null)
        ...widget.configuration.sources.map((source) => source.id),
    ];
    _automatic = widget.group?.automatic ?? false;
    _muted = widget.group?.muted ?? false;
    _masterVolume = widget.group?.masterVolume ?? 100;
  }

  @override
  Widget build(BuildContext context) {
    final assignedElsewhere = widget.configuration.groups
        .where((group) => group.id != widget.group?.id)
        .expand((group) => group.speakerIds)
        .toSet();
    final sourceNames = {
      for (final source in widget.configuration.sources) source.id: source.name,
    };
    return AlertDialog(
      title: Text(widget.group == null ? 'Create group' : 'Edit group'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 18),
              const Text('Speakers'),
              for (final speaker in widget.configuration.speakers)
                CheckboxListTile(
                  value: _speakerIds.contains(speaker.id),
                  title: Text(speaker.name),
                  subtitle: assignedElsewhere.contains(speaker.id)
                      ? const Text('Already assigned to another group')
                      : null,
                  onChanged: assignedElsewhere.contains(speaker.id)
                      ? null
                      : (selected) => setState(() {
                          if (selected == true) {
                            _speakerIds.add(speaker.id);
                          } else {
                            _speakerIds.remove(speaker.id);
                          }
                        }),
                ),
              const SizedBox(height: 12),
              const Text('Source priority'),
              for (var index = 0; index < _sourcePriority.length; index++)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(child: Text('${index + 1}')),
                  title: Text(
                    sourceNames[_sourcePriority[index]] ??
                        _sourcePriority[index],
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        onPressed: index == 0
                            ? null
                            : () => _move(index, index - 1),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        onPressed: index == _sourcePriority.length - 1
                            ? null
                            : () => _move(index, index + 1),
                        icon: const Icon(Icons.arrow_downward),
                      ),
                      IconButton(
                        onPressed: _sourcePriority.length == 1
                            ? null
                            : () => setState(
                                () => _sourcePriority.removeAt(index),
                              ),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    ],
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  for (final source in widget.configuration.sources)
                    if (!_sourcePriority.contains(source.id))
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: Text(source.name),
                        onPressed: () =>
                            setState(() => _sourcePriority.add(source.id)),
                      ),
                ],
              ),
              SwitchListTile(
                value: _automatic,
                title: const Text('Location volume'),
                subtitle: const Text(
                  'Requires calibrated sensors on every speaker',
                ),
                onChanged: (value) => setState(() => _automatic = value),
              ),
              SwitchListTile(
                value: _muted,
                title: const Text('Mute group'),
                onChanged: (value) => setState(() => _muted = value),
              ),
              Text('Master volume ${_masterVolume.round()}%'),
              Slider(
                value: _masterVolume,
                max: 100,
                divisions: 100,
                onChanged: (value) => setState(() => _masterVolume = value),
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
          onPressed:
              _nameController.text.trim().isEmpty || _sourcePriority.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  _GroupDraft(
                    name: _nameController.text.trim(),
                    speakerIds: _speakerIds.toList(),
                    sourcePriority: _sourcePriority,
                    automatic: _automatic,
                    masterVolume: _masterVolume,
                    muted: _muted,
                  ),
                ),
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _move(int from, int to) {
    setState(() {
      final source = _sourcePriority.removeAt(from);
      _sourcePriority.insert(to, source);
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
}

class _GroupDraft {
  const _GroupDraft({
    required this.name,
    required this.speakerIds,
    required this.sourcePriority,
    required this.automatic,
    required this.masterVolume,
    required this.muted,
  });

  final String name;
  final List<String> speakerIds;
  final List<String> sourcePriority;
  final bool automatic;
  final double masterVolume;
  final bool muted;
}
