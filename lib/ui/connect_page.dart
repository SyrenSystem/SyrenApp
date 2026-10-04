import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/services_providers.dart';
import '../providers/settings_provider.dart';
import 'profile/setup_page.dart';
import 'profile/syren_widgets.dart';
import 'syren_theme.dart';

/// First screen: find the hub, or say why it cannot be reached yet.
class ConnectPage extends ConsumerWidget {
  const ConnectPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final connection = ref.watch(mqttConnectionProvider);
    final address = settings.ip;
    final String? status = address.isEmpty
        ? null
        : connection.value == true
        ? 'Found the hub. Waiting for the Syren server to answer…'
        : connection.hasValue || connection.hasError
        ? "Can't reach $address yet. Trying again every few seconds."
        : 'Still looking for $address…';
    return Scaffold(
      body: SyrenPage(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
        spacing: 22,
        children: [
          const Text(
            'SYREN',
            style: TextStyle(
              fontFamily: SyrenFonts.sans,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 3.1,
              color: SyrenColors.ink,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Let's find your speakers", style: SyrenText.hero),
              const SizedBox(height: 8),
              Text(
                'Your phone needs to be on the same Wi-Fi as your Syren hub.',
                style: SyrenText.lead,
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MonoLabel('Hub address'),
              const SizedBox(height: 10),
              const HubAddressCard(buttonLabel: 'Connect'),
              if (status != null) ...[
                const SizedBox(height: 10),
                _StatusLine(status),
              ],
            ],
          ),
          Text(
            'The hub is the computer that runs the Syren server. Ask whoever set up Syren for its address.',
            style: SyrenText.small,
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: Border.all(color: SyrenColors.dashed, width: 1.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: SyrenColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: SyrenText.body.copyWith(
                fontSize: 14,
                color: SyrenColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
