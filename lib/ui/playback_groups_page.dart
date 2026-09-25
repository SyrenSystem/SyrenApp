import 'package:final_project/ui/app_feedback.dart';
import 'dart:async';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:final_project/services/volume_change_queue.dart';
import 'package:final_project/ui/command_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// A paused laptop session with Snapcast selected is not a muted group, but a configured mute still counts.
bool _groupOutputMuted(RtpStatus? playback, PlaybackGroup? group) =>
    playback?.outputMuted == true || (group?.muted ?? false);

// The receiver holds laptop audio muted for a reason other than a pending start or a Spotify handoff.
bool _laptopPaused(LocalAudioService service) =>
    service.rtp.state == 'readyMuted' &&
    !service.enablingPlayback &&
    !service.waitingForPriority;

bool _includesLaptopAudio(
  SystemConfiguration configuration,
  PlaybackGroup? group,
  LocalAudioService service,
) =>
    service.rtp.active &&
    group != null &&
    configuration.speakers.any(
      (speaker) =>
          group.speakerIds.contains(speaker.id) &&
          speaker.snapClientId == service.rtp.pairing?['snapclient_id'],
    );

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
    final audio = ref.read(localAudioServiceProvider);
    final localPlayback = _includesLaptopAudio(configuration, group, audio);
    final initialPlayback = localPlayback ? audio.rtp : null;
    final initialMuted = group?.muted ?? false;
    final draft = await showDialog<_GroupDraft>(
      context: context,
      builder: (context) =>
          _GroupEditor(configuration: configuration, group: group),
    );
    if (draft == null || !context.mounted) {
      return;
    }
    // Routine handoffs move the receiver generation while the dialog is open, so only a lost session skips the live controls.
    if (initialPlayback != null &&
        audio.rtp.active &&
        audio.rtp.session == initialPlayback.session) {
      try {
        if (draft.muted && !initialMuted) {
          await audio.muteRtp();
          if (audio.muteFeedback != null) throw StateError(audio.muteFeedback!);
        } else {
          final speaker = configuration.speakers.firstWhere(
            (speaker) =>
                speaker.snapClientId ==
                initialPlayback.pairing?['snapclient_id'],
          );
          if (draft.masterVolume != group?.masterVolume ||
              (draft.sourceLevels['laptop'] ?? 100) !=
                  group?.sourceLevel('laptop')) {
            await audio.setPlaybackLevels(
              groupVolume: draft.masterVolume,
              sourceLevel: draft.sourceLevels['laptop'] ?? 100,
              speakerLevel: speaker.level,
            );
          }
          if (!draft.muted && _laptopPaused(audio)) {
            if (audio.canUnmute) {
              // Confirms the saved volume again, then unmutes or hands off to Spotify by priority.
              await ref.read(groupAudioCoordinatorProvider).refresh();
              await audio.enablePlayback(
                groupVolume: draft.masterVolume,
                sourceLevel: draft.sourceLevels['laptop'] ?? 100,
                speakerLevel: speaker.level,
              );
            } else if (initialMuted) {
              throw StateError(
                'Wait for confirmed mute and receiver readiness.',
              );
            }
          }
        }
      } catch (error) {
        if (context.mounted) {
          showLatestSnackBar(
            context,
            SnackBar(
              content: Text(
                error is StateError
                    ? error.message.toString()
                    : error.toString(),
              ),
            ),
          );
        }
        return;
      }
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
          sourceLevels: draft.sourceLevels,
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
  bool _saving = false;
  int _editVersion = 0;
  double? _requestedValue;

  @override
  void initState() {
    super.initState();
    _masterVolume = widget.group.masterVolume;
  }

  @override
  void didUpdateWidget(covariant _GroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && !_saving) {
      _masterVolume = widget.group.masterVolume;
    }
  }

  @override
  Widget build(BuildContext context) {
    final audio = ref.watch(localAudioServiceProvider);
    final localPlayback = _includesLaptopAudio(
      widget.configuration,
      widget.group,
      audio,
    );
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
                  _groupOutputMuted(
                        localPlayback ? audio.rtp : null,
                        widget.group,
                      )
                      ? Icons.volume_off
                      : Icons.speaker_group,
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
                    localPlayback
                        ? 'Low-latency connected'
                        : widget.group.automatic
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
              onChanged: (value) {
                setState(() => _masterVolume = value);
                unawaited(_saveMasterVolume(value));
              },
              onChangeEnd: (value) {
                setState(() {
                  _dragging = false;
                  _masterVolume = value;
                });
                unawaited(_saveMasterVolume(value));
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

  Future<void> _saveMasterVolume(double value) async {
    final savedValue = ref
        .read(systemConfigurationProvider)
        ?.groups
        .where((candidate) => candidate.id == widget.group.id)
        .firstOrNull
        ?.masterVolume;
    if ((_saving && _requestedValue == value) ||
        (!_saving && savedValue == value)) {
      return;
    }
    _requestedValue = value;
    final version = ++_editVersion;
    _saving = true;
    try {
      final result = await ref
          .read(volumeChangeQueueProvider)
          .enqueue(
            'group:${widget.group.id}',
            (configuration) => _sendMasterVolume(
              value,
              configuration,
              () => mounted && version == _editVersion,
            ),
          );
      if (mounted && version == _editVersion && result?.success != true) {
        showCommandFeedback(context, result, 'Volume saved');
      }
    } catch (error) {
      if (mounted && version == _editVersion) {
        showLatestSnackBar(context, SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && version == _editVersion) {
        setState(() {
          _saving = false;
          if (!_dragging) {
            _masterVolume =
                ref
                    .read(systemConfigurationProvider)
                    ?.groups
                    .where((group) => group.id == widget.group.id)
                    .firstOrNull
                    ?.masterVolume ??
                widget.group.masterVolume;
          }
        });
      }
    }
  }

  Future<CommandResult?> _sendMasterVolume(
    double value,
    SystemConfiguration latest,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) throw const VolumeChangeSuperseded();
    final group = latest.groups
        .where((candidate) => candidate.id == widget.group.id)
        .firstOrNull;
    if (group == null) throw StateError('Group no longer exists');
    final audio = ref.read(localAudioServiceProvider);
    if (_includesLaptopAudio(latest, group, audio)) {
      final speaker = latest.speakers.firstWhere(
        (speaker) =>
            speaker.snapClientId == audio.rtp.pairing?['snapclient_id'],
      );
      await audio.setPlaybackLevels(
        isCurrent: isCurrent,
        groupVolume: value,
        sourceLevel: group.sourceLevel('laptop'),
        speakerLevel: speaker.level,
      );
    }
    if (!isCurrent()) throw const VolumeChangeSuperseded();
    return ref
        .read(mqttServiceProvider)
        .upsertGroup(
          expectedRevision: latest.revision,
          groupId: group.id,
          name: group.name,
          speakerIds: group.speakerIds,
          sourcePriority: group.sourcePriority,
          sourceLevels: group.sourceLevels,
          volumeMode: group.volumeMode,
          masterVolume: value,
          muted: group.muted,
        );
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
  bool _saving = false;
  int _editVersion = 0;
  double? _requestedValue;

  @override
  void initState() {
    super.initState();
    _level = widget.speaker.level;
  }

  @override
  void didUpdateWidget(covariant _SpeakerLevelRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && !_saving) {
      _level = widget.speaker.level;
    }
  }

  @override
  Widget build(BuildContext context) {
    final audio = ref.watch(localAudioServiceProvider);
    final localPlayback =
        audio.rtp.active &&
        audio.rtp.pairing?['snapclient_id'] == widget.speaker.snapClientId;
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
                onChanged: (value) {
                  setState(() => _level = value);
                  unawaited(_save(value));
                },
                onChangeEnd: (value) {
                  setState(() {
                    _dragging = false;
                    _level = value;
                  });
                  unawaited(_save(value));
                },
              ),
            ),
            SizedBox(width: 44, child: Text('${_level.round()}%')),
          ],
        ),
        if (widget.showUncalibratedHint && !localPlayback)
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

  Future<void> _save(double value) async {
    final savedValue = ref
        .read(systemConfigurationProvider)
        ?.speakers
        .where((candidate) => candidate.id == widget.speaker.id)
        .firstOrNull
        ?.level;
    if ((_saving && _requestedValue == value) ||
        (!_saving && savedValue == value)) {
      return;
    }
    _requestedValue = value;
    final version = ++_editVersion;
    _saving = true;
    try {
      final result = await ref
          .read(volumeChangeQueueProvider)
          .enqueue(
            'speaker:${widget.speaker.id}',
            (configuration) => _sendLevel(
              value,
              configuration,
              () => mounted && version == _editVersion,
            ),
          );
      if (mounted && version == _editVersion && result?.success != true) {
        showCommandFeedback(context, result, 'Speaker level saved');
      }
    } catch (error) {
      if (mounted && version == _editVersion) {
        showLatestSnackBar(context, SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && version == _editVersion) {
        setState(() {
          _saving = false;
          if (!_dragging) {
            _level =
                ref
                    .read(systemConfigurationProvider)
                    ?.speakers
                    .where((speaker) => speaker.id == widget.speaker.id)
                    .firstOrNull
                    ?.level ??
                widget.speaker.level;
          }
        });
      }
    }
  }

  Future<CommandResult?> _sendLevel(
    double value,
    SystemConfiguration configuration,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) throw const VolumeChangeSuperseded();
    final audio = ref.read(localAudioServiceProvider);
    if (audio.rtp.active &&
        audio.rtp.pairing?['snapclient_id'] == widget.speaker.snapClientId) {
      final group = configuration.groups
          .where((group) => group.speakerIds.contains(widget.speaker.id))
          .firstOrNull;
      await audio.setPlaybackLevels(
        isCurrent: isCurrent,
        groupVolume: group?.masterVolume ?? 0,
        sourceLevel: group?.sourceLevel('laptop') ?? 100,
        speakerLevel: value,
      );
    }
    if (!isCurrent()) throw const VolumeChangeSuperseded();
    return ref
        .read(mqttServiceProvider)
        .setSpeakerLevel(
          expectedRevision: configuration.revision,
          speakerId: widget.speaker.id,
          level: value,
        );
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
  late final Map<String, double> _sourceLevels;
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
    _sourceLevels = {...?widget.group?.sourceLevels};
    _automatic = widget.group?.automatic ?? false;
    // The receiver mutes itself briefly while starting or recovering, and that must not be saved as a group mute.
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
              const SizedBox(height: 16),
              const Text('Source balance'),
              const Text(
                'Lower the louder source. Master volume controls both.',
              ),
              for (final source in widget.configuration.sources) ...[
                Text(
                  '${source.name} ${(_sourceLevels[source.id] ?? 100).round()}%',
                ),
                Slider(
                  key: ValueKey('source-level-${source.id}'),
                  value: _sourceLevels[source.id] ?? 100,
                  max: 100,
                  divisions: 100,
                  label: '${(_sourceLevels[source.id] ?? 100).round()}%',
                  onChanged: (value) =>
                      setState(() => _sourceLevels[source.id] = value),
                ),
              ],
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
                    sourceLevels: _sourceLevels,
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
    required this.sourceLevels,
    required this.automatic,
    required this.masterVolume,
    required this.muted,
  });

  final String name;
  final List<String> speakerIds;
  final List<String> sourcePriority;
  final Map<String, double> sourceLevels;
  final bool automatic;
  final double masterVolume;
  final bool muted;
}
