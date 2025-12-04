import 'package:final_project/models/distance_item.dart';
import 'package:final_project/models/volume_item.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class VolumeControlPage extends ConsumerStatefulWidget {
  const VolumeControlPage({super.key});

  @override
  ConsumerState<VolumeControlPage> createState() => _VolumeControlPage();
}


class _VolumeControlPage extends ConsumerState<VolumeControlPage> {
  late List<DistanceItem> distanceItems = ref.read(distanceItemsProvider);
  late List<VolumeItem> volumeItems = ref.read(volumeItemsProvider);
  late final mqttClient = ref.read(mqttServiceProvider);

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {

    });
    return _buildContent();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Widget _buildContent() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0a101f),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ListView.builder(
                    itemCount: volumeItems.length,
                    itemBuilder: (context, index) {
                      final item = volumeItems[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Speaker ${item.id}: ${distanceItems.firstWhere((distanceItem) => distanceItem.id == item.id).label}",
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Slider(
                                value: item.volume.toDouble(),
                                min: 0,
                                max: 100,
                                divisions: 100,
                                label: item.volume.toString(),
                                onChanged: (double value) {

                                  ref.read(volumeItemsProvider.notifier).updateVolume(item.id, value.toInt());
                                  mqttClient.sendVolumeUpdate(item.id, value);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
