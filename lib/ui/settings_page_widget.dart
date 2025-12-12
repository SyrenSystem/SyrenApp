import 'package:final_project/providers/app_state_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/providers/settings_provider.dart';

class SettingsPageWidget extends ConsumerStatefulWidget {
  const SettingsPageWidget({super.key});

  @override
  ConsumerState<SettingsPageWidget> createState() => _SettingsPageWidgetState();
}

class _SettingsPageWidgetState extends ConsumerState<SettingsPageWidget> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  late final _distanceItems = ref.read(distanceItemsProvider);

  void _updateControllers(SettingsState settings) {
    if (_ipController.text != settings.ip) {
      _ipController.text = settings.ip;
    }
    if (_portController.text != settings.port.toString()) {
      _portController.text = settings.port.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch settings and update controllers when they change
    final settings = ref.watch(settingsProvider);

    // Update controllers immediately when settings change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateControllers(settings);
    });

    return _buildContent();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());

    if (ip.isEmpty || port == null || port <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Please enter a valid IP and port"),
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
          content: const Text("Settings saved successfully"),
          backgroundColor: const Color(0xFFd4af37),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Widget _buildContent() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0d121c),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
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

                // Connection Settings Section
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

                // IP Address Field
                _buildInputField(
                  controller: _ipController,
                  label: 'IP Address',
                  hint: '192.168.1.100',
                  icon: Icons.router,
                  keyboardType: TextInputType.text,
                ),
                const SizedBox(height: 16),

                // Port Field
                _buildInputField(
                  controller: _portController,
                  label: 'Port',
                  hint: '1883',
                  icon: Icons.network_check,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 32),

                // Save Button
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
                const SizedBox(height: 40),

                // Sensor Labels Section
                if (_distanceItems.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFd4af37).withValues(alpha: 0.2),
                        width: 1,
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
                        ..._distanceItems.asMap().entries.map((entry) {
                          final index = entry.key;
                          final item = entry.value;

                          // Abbreviate long MAC addresses
                          String displayId = item.id;
                          if (displayId.length > 12) {
                            displayId = '${displayId.substring(0, 6)}...${displayId.substring(displayId.length - 6)}';
                          }

                          return Column(
                            children: [
                              if (index > 0)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  child: Divider(
                                    color: const Color(0xFFd4af37).withValues(alpha: 0.1),
                                    height: 1,
                                  ),
                                ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    displayId,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _buildInputField(
                                    controller: TextEditingController(text: item.label),
                                    label: 'Label',
                                    hint: 'Enter label',
                                    icon: Icons.label,
                                    keyboardType: TextInputType.text,
                                    onChanged: (value) async {
                                      item.label = value.toString();
                                      await item.save();
                                    },
                                  ),
                                ],
                              ),
                            ],
                          );
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Bottom padding to account for navigation bar
                if (_distanceItems.length < 3)
                  SizedBox(height: 1000)
                else
                  SizedBox(height: 100)
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required TextInputType keyboardType,
    ValueChanged<String>? onChanged
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFd4af37).withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: TextField(
        onChanged: onChanged,
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
        ),
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
