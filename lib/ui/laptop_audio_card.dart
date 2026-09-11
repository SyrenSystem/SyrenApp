import 'package:final_project/ui/app_feedback.dart';
import 'package:final_project/models/system_configuration.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/services/local_audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class LaptopAudioCard extends ConsumerWidget {
  const LaptopAudioCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(localAudioServiceProvider);
    final enabled = ref.watch(localAudioEnabledProvider).value;
    if (!service.available || service.rtp.active) {
      return const SizedBox.shrink();
    }
    return Card(
      child: SwitchListTile(
        secondary: const Icon(Icons.computer),
        title: const Text('Laptop audio'),
        subtitle: const Text('Play through your speaker groups'),
        value: enabled ?? false,
        onChanged: service.rtp.state == 'idle' && enabled != null
            ? (value) async {
                if (!await service.setEnabled(value) && context.mounted) {
                  showLatestSnackBar(
                    context,
                    const SnackBar(
                      content: Text('Could not change the audio output.'),
                    ),
                  );
                }
                ref.invalidate(localAudioEnabledProvider);
              }
            : null,
      ),
    );
  }
}

class SpeakerLaptopAudio extends ConsumerStatefulWidget {
  const SpeakerLaptopAudio({super.key, required this.receiver});
  final SnapClientInfo receiver;

  @override
  ConsumerState<SpeakerLaptopAudio> createState() => _SpeakerLaptopAudioState();
}

class _SpeakerLaptopAudioState extends ConsumerState<SpeakerLaptopAudio> {
  bool _settingUp = false;
  String? _error;

  Future<void> _toggle(LocalAudioService service, bool enabled) async {
    setState(() => _error = null);
    try {
      if (!enabled) {
        await service.stopRtp();
        return;
      }
      if (service.rtp.pairing?['snapclient_id'] != widget.receiver.id) {
        setState(() => _settingUp = true);
        await showDialog<void>(
          context: context,
          builder: (context) => ReceiverConnectionDialog(
            service: service,
            receivers: [widget.receiver],
          ),
        );
        if (!mounted) return;
        await service.refreshRtp();
        if (service.rtp.pairing?['snapclient_id'] != widget.receiver.id) return;
      }
      final configuration = ref.read(systemConfigurationProvider);
      final speaker = configuration?.speakers
          .where((speaker) => speaker.snapClientId == widget.receiver.id)
          .firstOrNull;
      if (speaker == null) {
        throw StateError(
          'Wait for the speaker settings to load, then try again.',
        );
      }
      final group = configuration!.groups
          .where((group) => group.speakerIds.contains(speaker.id))
          .firstOrNull;
      await ref.read(groupAudioCoordinatorProvider).refresh();
      if (!mounted) return;
      await service.enablePlayback(
        groupVolume: group?.masterVolume ?? 100,
        sourceLevel: group?.sourceLevel('laptop') ?? 100,
        speakerLevel: speaker.level,
        muted: group?.muted ?? false,
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message.toString()
              : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _settingUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(localAudioServiceProvider);
    if (!service.available) return const SizedBox.shrink();
    final status = service.rtp;
    final selected = status.pairing?['snapclient_id'] == widget.receiver.id;
    final enabled =
        selected &&
        (service.waitingForPriority ||
            service.enablingPlayback ||
            [
              'preparing',
              'playing',
              'readyMuted',
              'recoveringMuted',
              'recoveryPending',
              'stopping',
            ].contains(status.state));
    final otherSpeakerActive = !selected && status.state != 'idle';
    final message =
        _error ?? (selected ? service.rtpError ?? status.error : null);
    final label = message != null
        ? (status.state == 'stopping'
              ? 'Disconnecting...'
              : 'Connection needs attention')
        : selected && service.waitingForPriority
        ? 'Connected · Following group priority'
        : selected
        ? switch (status.state) {
            'preparing' => 'Connecting...',
            'playing' => 'Playing laptop audio',
            'recoveringMuted' => 'Reconnecting...',
            'readyMuted' =>
              service.enablingPlayback
                  ? 'Connecting...'
                  : status.outputMuted == true
                  ? 'Muted'
                  : service.resumePending
                  ? 'Reconnected · Resuming'
                  : 'Paused · Snapcast selected',
            'stopping' => 'Disconnecting...',
            'recoveryPending' => 'Connection needs attention',
            _ => 'Experimental · One speaker',
          }
        : 'Experimental · One speaker';
    return SwitchListTile(
      title: const Text('Low-latency laptop audio'),
      subtitle: Text(
        service.muteFeedback ?? (_settingUp ? 'Setting up...' : label),
      ),
      value: enabled,
      onChanged: _settingUp || otherSpeakerActive || status.state == 'stopping'
          ? null
          : (value) => _toggle(service, value),
    );
  }
}

class ReceiverConnectionDialog extends StatefulWidget {
  const ReceiverConnectionDialog({
    super.key,
    required this.service,
    required this.receivers,
  });
  final LocalAudioService service;
  final List<SnapClientInfo> receivers;

  @override
  State<ReceiverConnectionDialog> createState() =>
      ReceiverConnectionDialogState();
}

class ReceiverConnectionDialogState extends State<ReceiverConnectionDialog> {
  final _form = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _key = TextEditingController();
  SnapClientInfo? _receiver;
  Map<String, dynamic>? _candidate;
  bool _verified = false;
  bool _busy = false;
  bool _discovering = false;
  int _discoveryRevision = 0;
  String? _discoveryMessage;
  String? _error;

  @override
  void initState() {
    super.initState();
    final pairing = widget.service.rtp.pairing;
    _receiver =
        widget.receivers
            .where((receiver) => receiver.id == pairing?['snapclient_id'])
            .firstOrNull ??
        widget.receivers.firstOrNull;
    if (_receiver != null) _discover(_receiver!);
  }

  Future<void> _discover(SnapClientInfo receiver) async {
    final revision = ++_discoveryRevision;
    setState(() {
      _receiver = receiver;
      _discovering = true;
      _discoveryMessage = null;
      _error = null;
      _host.clear();
      _user.clear();
      _key.clear();
      _port.text = '22';
    });
    try {
      final defaults = await widget.service.rtpRequest('pair-discover', {
        'snapclient_id': receiver.id,
        'name': receiver.name,
      });
      if (!mounted || revision != _discoveryRevision) return;
      setState(() {
        _host.text = defaults['host'] as String? ?? '';
        _user.text = defaults['user'] as String? ?? '';
        _key.text = defaults['key'] as String? ?? '';
        _port.text = '${defaults['port'] ?? 22}';
        _discoveryMessage = defaults['message'] as String?;
      });
    } catch (error) {
      if (mounted && revision == _discoveryRevision) {
        setState(() => _error = _errorMessage(error));
      }
    } finally {
      if (mounted && revision == _discoveryRevision) {
        setState(() => _discovering = false);
      }
    }
  }

  Future<void> _submit() async {
    if (_candidate == null && !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_candidate == null) {
        final candidate = await widget.service.rtpRequest('pair-probe', {
          'snapclient_id': _receiver!.id,
          'name': _receiver!.name,
          'host': _host.text.trim(),
          'user': _user.text.trim(),
          'port': int.tryParse(_port.text.trim()),
          'key': _key.text.trim(),
        });
        if (mounted) setState(() => _candidate = candidate);
      } else {
        await widget.service.rtpRequest('pair', {
          'challenge': _candidate!['challenge'],
          'verified_fingerprint': _candidate!['fingerprint'],
          'repair_changed_key': _candidate!['changed_key'] == true && _verified,
        });
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _errorMessage(Object error) =>
      error is StateError ? error.message.toString() : error.toString();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect speaker'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_candidate == null) ...[
                if (widget.receivers.length > 1)
                  DropdownButtonFormField<SnapClientInfo>(
                    initialValue: _receiver,
                    decoration: const InputDecoration(
                      labelText: 'Discovered Snapclient',
                    ),
                    items: [
                      for (final receiver in widget.receivers)
                        DropdownMenuItem(
                          value: receiver,
                          child: Text('${receiver.name} (${receiver.id})'),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) _discover(value);
                          },
                  ),
                if (_discovering) ...[
                  const LinearProgressIndicator(),
                  const Text('Finding receiver connection details...'),
                ],
                if (_discoveryMessage != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_discoveryMessage!),
                  ),
                TextFormField(
                  controller: _host,
                  enabled: !_busy && !_discovering,
                  decoration: const InputDecoration(labelText: 'SSH host'),
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Enter the receiver hostname or IP address.'
                      : null,
                ),
                TextFormField(
                  controller: _user,
                  enabled: !_busy && !_discovering,
                  decoration: const InputDecoration(labelText: 'SSH user'),
                  validator: (value) =>
                      !RegExp(
                        r'^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$',
                      ).hasMatch((value ?? '').trim())
                      ? 'Enter the login name used on the receiver.'
                      : null,
                ),
                ExpansionTile(
                  title: const Text('Advanced SSH settings'),
                  tilePadding: EdgeInsets.zero,
                  maintainState: true,
                  children: [
                    TextFormField(
                      controller: _port,
                      enabled: !_busy && !_discovering,
                      decoration: const InputDecoration(labelText: 'SSH port'),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        final port = int.tryParse((value ?? '').trim());
                        return port == null || port < 1 || port > 65535
                            ? 'Enter a port between 1 and 65535.'
                            : null;
                      },
                    ),
                    TextFormField(
                      controller: _key,
                      enabled: !_busy && !_discovering,
                      decoration: const InputDecoration(
                        labelText: 'SSH key path (empty for agent)',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Discovery finds the receiver, but does not grant SSH access. Receiver installation and host verification are needed once. Your SSH agent supplies the login key; Syren never requests or stores a password.',
                ),
                if (widget.receivers.isEmpty)
                  const Text(
                    'Start Snapclient so it can be discovered before pairing.',
                  ),
              ] else ...[
                if (_candidate!['changed_key'] == true)
                  const Text(
                    'Host key changed. Operation is blocked until you explicitly re-pair.',
                    style: TextStyle(color: Colors.orangeAccent),
                  ),
                SelectableText(_candidate!['fingerprint'] as String),
                const SizedBox(height: 12),
                const Text(
                  'Compare this fingerprint with a trusted receiver terminal:',
                ),
                const SelectableText(
                  'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256',
                ),
                CheckboxListTile(
                  value: _verified,
                  onChanged: (value) =>
                      setState(() => _verified = value ?? false),
                  title: const Text(
                    'I verified this fingerprint against the trusted receiver source.',
                  ),
                ),
              ],
              if (_error != null) SelectableText(_error!),
            ],
          ),
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
            !_busy &&
                !_discovering &&
                _receiver != null &&
                (_candidate == null || _verified)
            ? _submit
            : null,
        child: Text(
          _candidate == null ? 'Show host fingerprint' : 'Pin verified key',
        ),
      ),
    ],
  );

  @override
  void dispose() {
    for (final controller in [_host, _user, _port, _key]) {
      controller.dispose();
    }
    super.dispose();
  }
}
