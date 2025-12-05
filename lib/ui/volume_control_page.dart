import 'package:final_project/models/distance_item.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class VolumeControlPage extends ConsumerWidget {
  const VolumeControlPage({super.key});

  IconData _getVolumeIcon(double volume) {
    if (volume == 0) return Icons.volume_off;
    if (volume <= 50) return Icons.volume_down;
    return Icons.volume_up;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final distanceItems = ref.watch(distanceItemsProvider);
    final mqttClient = ref.read(mqttServiceProvider);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0d121c),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Header with gold gradient
            Padding(
              padding: const EdgeInsets.only(top: 60, bottom: 16),
              child: Center(
                child: ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [
                      Color(0xFFf0e68c),
                      Color(0xFFd4af37),
                      Color(0xFFc19a27),
                    ],
                  ).createShader(bounds),
                  child: const Text(
                    'VOLUME CONTROL',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 8,
                      color: Colors.white,
                      fontFamily: 'serif',
                    ),
                  ),
                ),
              ),
            ),

            // Content
            Expanded(
              child: distanceItems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.speaker_group_outlined,
                            size: 64,
                            color: const Color(0xFFd4af37).withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No speakers connected',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      itemCount: distanceItems.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final item = distanceItems[index];

                        // Abbreviate long MAC addresses
                        String displayId = item.id;
                        if (displayId.length > 12) {
                          displayId = '${displayId.substring(0, 6)}...${displayId.substring(displayId.length - 6)}';
                        }

                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                              // ID and Label row
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    displayId,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  if (item.label != 'unknown')
                                    Text(
                                      item.label,
                                      style: TextStyle(
                                        color: const Color(0xFFd4af37).withValues(alpha: 0.8),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),

                              // Slider
                              SliderTheme(
                                data: SliderThemeData(
                                  activeTrackColor: const Color(0xFFd4af37),
                                  inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
                                  thumbColor: const Color(0xFFd4af37),
                                  overlayColor: const Color(0xFFd4af37).withValues(alpha: 0.2),
                                  trackHeight: 4,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                                ),
                                child: Slider(
                                  value: item.volume,
                                  min: 0,
                                  max: 100,
                                  divisions: 100,
                                  onChanged: (double value) async {
                                    ref.read(distanceItemsProvider.notifier).updateVolume(item.id, value);
                                    mqttClient.sendVolumeUpdate(item.id, value);
                                    item.volume = value;
                                    await item.save();
                                  },
                                ),
                              ),

                              const SizedBox(height: 4),

                              // Volume display row
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Icon(
                                    _getVolumeIcon(item.volume),
                                    color: const Color(0xFFd4af37),
                                    size: 18,
                                  ),
                                  Text(
                                    '${item.volume.toInt()}%',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
