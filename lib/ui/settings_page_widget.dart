import 'dart:async';

import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/settings_provider.dart';
import 'package:final_project/util/format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SettingsPageWidget extends ConsumerStatefulWidget {
  const SettingsPageWidget({super.key});

  @override
  ConsumerState<SettingsPageWidget> createState() => _SettingsPageWidgetState();
}

class _SettingsPageWidgetState extends ConsumerState<SettingsPageWidget> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final distanceItems = ref.watch(distanceItemsProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_ipController.text != settings.ip) {
        _ipController.text = settings.ip;
      }
      if (_portController.text != settings.port.toString()) {
        _portController.text = settings.port.toString();
      }
    });

    return Container(
      decoration: const BoxDecoration(color: Color(0xFF0d121c)),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [
                      Color(0xFFf0e68c),
                      Color(0xFFd4af37),
                      Color(0xFFc19a27),
                    ],
                  ).createShader(bounds),
                  child: const Text(
                    'SETTINGS',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 6,
                      color: Colors.white,
                      fontFamily: 'serif',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),
              Text(
                'MQTT Connection',
                style: TextStyle(
                  color: const Color(0xFFd4af37).withValues(alpha: 0.8),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 20),
              _InputField(
                controller: _ipController,
                label: 'IP Address',
                hint: '192.168.1.100',
                icon: Icons.router,
                keyboardType: TextInputType.text,
              ),
              const SizedBox(height: 16),
              _InputField(
                controller: _portController,
                label: 'Port',
                hint: '1883',
                icon: Icons.network_check,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saveSettings,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFd4af37),
                    foregroundColor: const Color(0xFF0d121c),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 8,
                    shadowColor: const Color(0xFFd4af37).withValues(alpha: 0.3),
                  ),
                  child: const Text(
                    'SAVE SETTINGS',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
              if (distanceItems.isNotEmpty) ...[
                const SizedBox(height: 40),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFd4af37).withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SENSOR LABELS',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                          color: const Color(0xFFd4af37).withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(height: 16),
                      for (
                        var index = 0;
                        index < distanceItems.length;
                        index++
                      ) ...[
                        if (index > 0)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Divider(
                              color: const Color(
                                0xFFd4af37,
                              ).withValues(alpha: 0.1),
                              height: 1,
                            ),
                          ),
                        Text(
                          abbreviateId(distanceItems[index].id),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 8),
                        SensorLabelField(
                          key: ValueKey(distanceItems[index].id),
                          id: distanceItems[index].id,
                          label: distanceItems[index].label,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveSettings() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (ip.isEmpty || port == null || port <= 0 || port > 65535) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a valid IP and port'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    await ref.read(settingsProvider.notifier).saveSettings(ip, port);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Settings saved successfully'),
          backgroundColor: const Color(0xFFd4af37),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }
}

class SensorLabelField extends ConsumerStatefulWidget {
  const SensorLabelField({required this.id, required this.label, super.key});

  final String id;
  final String label;

  @override
  ConsumerState<SensorLabelField> createState() => _SensorLabelFieldState();
}

class _SensorLabelFieldState extends ConsumerState<SensorLabelField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late String _lastCommittedLabel;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.label);
    _lastCommittedLabel = widget.label;
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(SensorLabelField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && widget.label != _lastCommittedLabel) {
      _controller.text = widget.label;
      _lastCommittedLabel = widget.label;
    }
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) {
      unawaited(_commit());
    }
  }

  Future<void> _commit() async {
    final label = _controller.text;
    if (label == _lastCommittedLabel) {
      return;
    }
    _lastCommittedLabel = label;
    await ref
        .read(distanceItemsProvider.notifier)
        .commitLabel(widget.id, label);
  }

  @override
  Widget build(BuildContext context) {
    return _InputField(
      controller: _controller,
      focusNode: _focusNode,
      label: 'Label',
      hint: 'Enter label',
      icon: Icons.label,
      keyboardType: TextInputType.text,
      onSubmitted: (_) => unawaited(_commit()),
    );
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }
}

class _InputField extends StatelessWidget {
  const _InputField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    required this.keyboardType,
    this.focusNode,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType keyboardType;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFd4af37).withValues(alpha: 0.2),
        ),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: keyboardType,
        onSubmitted: onSubmitted,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(
            color: const Color(0xFFd4af37).withValues(alpha: 0.7),
            fontSize: 14,
          ),
          hintStyle: TextStyle(
            color: Colors.grey.withValues(alpha: 0.5),
            fontSize: 14,
          ),
          prefixIcon: Icon(
            icon,
            color: const Color(0xFFd4af37).withValues(alpha: 0.7),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
    );
  }
}
