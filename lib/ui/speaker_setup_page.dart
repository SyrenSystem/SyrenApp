import 'dart:async';

import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/measurement_provider.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/ui/command_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SpeakerSetupPage extends ConsumerWidget {
  const SpeakerSetupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configuration = ref.watch(systemConfigurationProvider);
    final runtime = ref.watch(systemRuntimeProvider);
    final localAudio = ref.watch(localAudioEnabledProvider);
    final localAudioEnabled = localAudio.value;
    return Container(
      color: const Color(0xFF0d121c),
      child: SafeArea(
        child: configuration == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 120),
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'SPEAKERS',
                          style: TextStyle(
                            color: Color(0xFFd4af37),
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: runtime == null
                            ? null
                            : () => _editSpeaker(
                                context,
                                ref,
                                configuration,
                                runtime,
                                null,
                              ),
                        icon: const Icon(Icons.add),
                        label: const Text('Speaker'),
                      ),
                    ],
                  ),
                  if (localAudioEnabled != null) ...[
                    const SizedBox(height: 20),
                    Card(
                      child: SwitchListTile(
                        value: localAudioEnabled,
                        title: const Text('Laptop audio output'),
                        subtitle: const Text(
                          'Send desktop sound to SyrenSystem instead of the built-in speakers.',
                        ),
                        secondary: const Icon(Icons.computer),
                        onChanged: (value) =>
                            unawaited(_setLocalAudio(context, ref, value)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (runtime != null && !runtime.snapserverOnline)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Snapserver offline',
                        style: TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                  if (configuration.speakers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: Center(
                        child: Text(
                          'No speakers configured. Start a Snapclient, then add it here.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ),
                  for (final speaker in configuration.speakers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _SpeakerCard(
                        configuration: configuration,
                        runtime: runtime,
                        speaker: speaker,
                        onEdit: () => _editSpeaker(
                          context,
                          ref,
                          configuration,
                          runtime,
                          speaker,
                        ),
                        onDelete: () => _deleteSpeaker(
                          context,
                          ref,
                          configuration,
                          speaker,
                        ),
                        onCalibrate: speaker.sensorId == null
                            ? null
                            : () => _calibrate(context, ref, speaker),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _setLocalAudio(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    final success = await ref
        .read(localAudioServiceProvider)
        .setEnabled(enabled);
    ref.invalidate(localAudioEnabledProvider);
    if (context.mounted && !success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to change the laptop audio output.'),
        ),
      );
    }
  }

  Future<void> _editSpeaker(
    BuildContext context,
    WidgetRef ref,
    SystemConfiguration configuration,
    SystemRuntime? runtime,
    ConfiguredSpeaker? speaker,
  ) async {
    final sensorIds = ref
        .read(distanceItemsProvider)
        .map((item) => item.id)
        .toList();
    final draft = await showDialog<_SpeakerDraft>(
      context: context,
      builder: (context) => _SpeakerEditor(
        configuration: configuration,
        runtime: runtime,
        speaker: speaker,
        sensorIds: sensorIds,
      ),
    );
    if (draft == null || !context.mounted) {
      return;
    }
    final result = await ref
        .read(mqttServiceProvider)
        .configureSpeaker(
          expectedRevision: configuration.revision,
          speakerId: speaker?.id,
          name: draft.name,
          snapClientId: draft.snapClientId,
          sensorId: draft.sensorId,
          fullVolumeDistance: draft.fullVolumeDistance,
          muteDistance: draft.muteDistance,
        );
    if (context.mounted) {
      showCommandFeedback(context, result, 'Speaker saved');
    }
  }

  Future<void> _deleteSpeaker(
    BuildContext context,
    WidgetRef ref,
    SystemConfiguration configuration,
    ConfiguredSpeaker speaker,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${speaker.name}?'),
        content: const Text(
          'The Snapclient remains available and can be added again.',
        ),
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
        .deleteSpeaker(
          expectedRevision: configuration.revision,
          speakerId: speaker.id,
        );
    final sensorId = speaker.sensorId;
    if (result?.success == true && sensorId != null) {
      await ref
          .read(desiredSpeakerConnectionsProvider.notifier)
          .forget(sensorId);
    }
    if (context.mounted) {
      showCommandFeedback(context, result, 'Speaker deleted');
    }
  }

  Future<void> _calibrate(
    BuildContext context,
    WidgetRef ref,
    ConfiguredSpeaker speaker,
  ) async {
    final connected = await ref
        .read(measurementControllerProvider)
        .connectSpeaker(speaker.sensorId!);
    if (!context.mounted) {
      return;
    }
    final grouped =
        ref.read(systemConfigurationProvider)?.isSpeakerGrouped(speaker.id) ??
        true;
    final message = !connected
        ? 'Start measurement and stand beside ${speaker.name} first.'
        : grouped
        ? 'Calibration requested for ${speaker.name}.'
        : 'Calibration requested for ${speaker.name}.'
              ' Add it to a playback group to hear audio.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SpeakerCard extends StatelessWidget {
  const _SpeakerCard({
    required this.configuration,
    required this.runtime,
    required this.speaker,
    required this.onEdit,
    required this.onDelete,
    required this.onCalibrate,
  });

  final SystemConfiguration configuration;
  final SystemRuntime? runtime;
  final ConfiguredSpeaker speaker;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onCalibrate;

  @override
  Widget build(BuildContext context) {
    final online =
        runtime?.onlineSnapClients.any(
          (client) => client.id == speaker.snapClientId,
        ) ??
        false;
    final matchingGroups = configuration.groups
        .where((group) => group.speakerIds.contains(speaker.id))
        .toList();
    final groupName = matchingGroups.isEmpty ? null : matchingGroups.first.name;
    return Card(
      color: Colors.black.withValues(alpha: 0.28),
      child: ListTile(
        leading: Icon(
          online ? Icons.speaker : Icons.speaker_outlined,
          color: online ? const Color(0xFFd4af37) : Colors.white38,
        ),
        title: Text(speaker.name),
        subtitle: Text(
          '${speaker.snapClientId}\n'
          '${groupName ?? 'No group'} · '
          '${speaker.sensorId == null
              ? 'Manual only'
              : speaker.calibrated
              ? 'Calibrated'
              : 'Needs calibration'}',
        ),
        isThreeLine: true,
        trailing: Wrap(
          children: [
            if (onCalibrate != null && !speaker.calibrated)
              IconButton(
                tooltip: 'Calibrate',
                onPressed: onCalibrate,
                icon: const Icon(Icons.my_location),
              ),
            IconButton(onPressed: onEdit, icon: const Icon(Icons.edit)),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeakerEditor extends StatefulWidget {
  const _SpeakerEditor({
    required this.configuration,
    required this.runtime,
    required this.speaker,
    required this.sensorIds,
  });

  final SystemConfiguration configuration;
  final SystemRuntime? runtime;
  final ConfiguredSpeaker? speaker;
  final List<String> sensorIds;

  @override
  State<_SpeakerEditor> createState() => _SpeakerEditorState();
}

class _SpeakerEditorState extends State<_SpeakerEditor> {
  late final TextEditingController _nameController;
  late final TextEditingController _fullDistanceController;
  late final TextEditingController _muteDistanceController;
  String? _snapClientId;
  String? _sensorId;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.speaker?.name ?? '');
    _fullDistanceController = TextEditingController(
      text: '${widget.speaker?.fullVolumeDistance.round() ?? 1000}',
    );
    _muteDistanceController = TextEditingController(
      text: '${widget.speaker?.muteDistance.round() ?? 5000}',
    );
    _snapClientId = widget.speaker?.snapClientId;
    _sensorId = widget.speaker?.sensorId;
  }

  @override
  Widget build(BuildContext context) {
    final usedClients = widget.configuration.speakers
        .where((speaker) => speaker.id != widget.speaker?.id)
        .map((speaker) => speaker.snapClientId)
        .toSet();
    final clients = <SnapClientInfo>[
      ...?widget.runtime?.onlineSnapClients.where(
        (client) => !usedClients.contains(client.id),
      ),
      if (widget.speaker != null &&
          widget.runtime?.onlineSnapClients.any(
                (client) => client.id == widget.speaker!.snapClientId,
              ) !=
              true)
        SnapClientInfo(
          id: widget.speaker!.snapClientId,
          name: widget.speaker!.snapClientId,
        ),
    ];
    final sensorChoices = <String>{
      ...widget.sensorIds,
      if (_sensorId != null) _sensorId!,
    }.toList()..sort();
    return AlertDialog(
      title: Text(widget.speaker == null ? 'Add speaker' : 'Edit speaker'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Speaker name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _snapClientId,
                decoration: const InputDecoration(labelText: 'Snapclient'),
                items: [
                  for (final client in clients)
                    DropdownMenuItem(
                      value: client.id,
                      child: Text('${client.name} (${client.id})'),
                    ),
                ],
                onChanged: (value) => setState(() => _snapClientId = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _sensorId,
                decoration: const InputDecoration(labelText: 'Location sensor'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('None, manual volume only'),
                  ),
                  for (final sensorId in sensorChoices)
                    DropdownMenuItem<String?>(
                      value: sensorId,
                      child: Text(sensorId),
                    ),
                ],
                onChanged: (value) => setState(() => _sensorId = value),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _fullDistanceController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Full volume distance in millimeters',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _muteDistanceController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Mute distance in millimeters',
                ),
              ),
              if (_validationError case final validationError?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    validationError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  void _save() {
    final name = _nameController.text.trim();
    final snapClientId = _snapClientId;
    final fullDistance = double.tryParse(_fullDistanceController.text);
    final muteDistance = double.tryParse(_muteDistanceController.text);
    final String? validationError;
    if (snapClientId == null) {
      validationError = 'Choose a Snapclient';
    } else if (name.isEmpty) {
      validationError = 'Enter a name';
    } else if (fullDistance == null ||
        !fullDistance.isFinite ||
        fullDistance < 0) {
      validationError = 'Enter a full volume distance of 0 or more';
    } else if (muteDistance == null ||
        !muteDistance.isFinite ||
        muteDistance <= fullDistance) {
      validationError = 'Mute distance must exceed full volume distance';
    } else {
      validationError = null;
    }
    if (validationError != null) {
      setState(() => _validationError = validationError);
      return;
    }
    _validationError = null;
    Navigator.pop(
      context,
      _SpeakerDraft(
        name: name,
        snapClientId: snapClientId!,
        sensorId: _sensorId,
        fullVolumeDistance: fullDistance!,
        muteDistance: muteDistance!,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _fullDistanceController.dispose();
    _muteDistanceController.dispose();
    super.dispose();
  }
}

class _SpeakerDraft {
  const _SpeakerDraft({
    required this.name,
    required this.snapClientId,
    required this.sensorId,
    required this.fullVolumeDistance,
    required this.muteDistance,
  });

  final String name;
  final String snapClientId;
  final String? sensorId;
  final double fullVolumeDistance;
  final double muteDistance;
}
