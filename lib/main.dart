import 'package:final_project/ui/volume_control_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/ui/location_view_page.dart';
import 'package:final_project/ui/settings_page_widget.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/measurement_provider.dart';
import 'package:final_project/providers/settings_provider.dart';

void main() {
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Syren App',
      home: const MainPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState(){
    return _MainPageState();
  }
}

class _MainPageState extends ConsumerState<MainPage> {
  Future<void> _startMeasurement() async {
    final controller = ref.read(measurementControllerProvider);
    final settings = ref.read(settingsProvider);

    if (controller.isConnected) {
      controller.stopMeasurement();
      setState(() {}); // Rebuild to update button text
      return;
    }

    if (settings.ip.isEmpty || settings.port <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please configure MQTT settings first.")));
      }
      return;
    }

    final error = await controller.startMeasurement(settings.ip, settings.port);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)));
    }

    setState(() {}); // Rebuild to update button text
  }

  @override
  Widget build(BuildContext context) {
    final selectedNavIndex = ref.watch(selectedNavIndexProvider);
    final distanceItems = ref.watch(distanceItemsProvider);
    final volumeItems = ref.watch(volumeItemsProvider);
    final userPosition = ref.watch(userPositionProvider);
    final speakers = ref.watch(speakersProvider);
    final controller = ref.read(measurementControllerProvider);

    // workaround: ensure that settings are available for ui actions
    final dummy = ref.read(settingsProvider);

    final List<Widget> pages = [
      // Distance Page (Location View)
      LocationViewPage(
        userPosition: userPosition,
        speakers: speakers.values.toList(),
      ),

      // Volume Control Page
      VolumeControlPage(),

      // Padding(
      //   padding: const EdgeInsets.all(16.0),
      //   child: ListView.builder(
      //     itemCount: volumeItems.length,
      //     itemBuilder: (context, index) {
      //       final item = volumeItems[index];
      //       return Card(
      //         child: Padding(
      //           padding: const EdgeInsets.all(16.0),
      //           child: Column(
      //             crossAxisAlignment: CrossAxisAlignment.start,
      //             children: [
      //               Text(
      //                 "Speaker ${item.id}",
      //                 style: const TextStyle(
      //                   fontSize: 16,
      //                   fontWeight: FontWeight.bold,
      //                 ),
      //               ),
      //               Slider(
      //                 value: item.volume.toDouble(),
      //                 min: 0,
      //                 max: 100,
      //                 divisions: 100,
      //                 label: item.volume.toString(),
      //                 onChanged: (double value) {
      //                   ref.read(volumeItemsProvider.notifier).updateVolume(
      //                         item.id,
      //                         value.toInt(),
      //                       );
      //                 },
      //               ),
      //             ],
      //           ),
      //         ),
      //       );
      //     },
      //   ),
      // ),

      // Settings Page
      const SettingsPageWidget(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          pages[selectedNavIndex],

          // Start Measurement Button - hovering over location view
          if (selectedNavIndex == 0)
            Positioned(
              left: 24,
              right: 24,
              bottom: 140,
              child: ElevatedButton(
                onPressed: _startMeasurement,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFd4af37),
                  foregroundColor: const Color(0xFF0a101f),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 8,
                  shadowColor: const Color(0xFFd4af37).withValues(alpha: 0.3),
                ),
                child: Text(
                  controller.isConnected ? 'STOP MEASUREMENT' : 'START MEASUREMENT',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),

          Positioned(
            left: 24,
            right: 24,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF090c13),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildNavItem(
                        icon: Icons.social_distance,
                        label: 'Distance',
                        index: 0,
                        isSelected: selectedNavIndex == 0,
                        onTap: () {
                          ref.read(selectedNavIndexProvider.notifier).state = 0;
                        },
                      ),
                      _buildNavItem(
                        icon: Icons.volume_up_rounded,
                        label: 'Volume',
                        index: 1,
                        isSelected: selectedNavIndex == 1,
                        onTap: () {
                          ref.read(selectedNavIndexProvider.notifier).state = 1;
                        },
                      ),
                      _buildNavItem(
                        icon: Icons.settings,
                        label: 'Settings',
                        index: 2,
                        isSelected: selectedNavIndex == 2,
                        onTap: () {
                          ref.read(selectedNavIndexProvider.notifier).state = 2;
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required int index,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? const Color(0xFFd4af37) : const Color(0xFF808080),
              size: 32,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? const Color(0xFFd4af37) : const Color(0xFF808080),
                fontSize: 16,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
