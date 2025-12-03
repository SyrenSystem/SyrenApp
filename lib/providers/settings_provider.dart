import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Settings State Notifier
class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier() : super(SettingsState(ip: '', port: 1883)) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    state = SettingsState(
      ip: prefs.getString('ip') ?? '192.168.2.51',
      port: prefs.getInt('port') ?? 1883,
    );
  }

  Future<void> saveSettings(String ip, int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ip', ip);
    await prefs.setInt('port', port);

    state = SettingsState(ip: ip, port: port);
  }

  void updateIp(String ip) {
    state = SettingsState(ip: ip, port: state.port);
  }

  void updatePort(int port) {
    state = SettingsState(ip: state.ip, port: port);
  }
}

// Settings State
class SettingsState {
  final String ip;
  final int port;

  SettingsState({required this.ip, required this.port});
}

// Provider
final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier();
});
