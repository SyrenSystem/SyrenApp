import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/ui/location_view_page.dart';
import 'package:final_project/ui/settings_page_widget.dart';
import 'package:final_project/ui/playback_groups_page.dart';
import 'package:final_project/ui/speaker_setup_page.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/measurement_provider.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/providers/settings_provider.dart';
import 'package:final_project/util/format.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'models/distance_item.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(DistanceItemAdapter());
  await Hive.openBox<DistanceItem>('distance_items');
  await Hive.openBox<bool>('speaker_connections');
  await Hive.openBox<String>('syren_metadata');
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyrenSystem',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFd4af37),
          brightness: Brightness.dark,
        ),
      ),
      home: const MainPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() {
    return _MainPageState();
  }
}

class _MainPageState extends ConsumerState<MainPage> {
  Future<void> _startMeasurement() async {
    final controller = ref.read(measurementControllerProvider);
    final settings = ref.read(settingsProvider);

    if (controller.isConnected) {
      await controller.stopMeasurement();
      setState(() {}); // Rebuild to update button text
      return;
    }

    if (settings.ip.isEmpty || settings.port <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Please configure MQTT settings first."),
          ),
        );
      }
      return;
    }

    final error = await controller.startMeasurement();
    if (error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }

    setState(() {}); // Rebuild to update button text
  }

  @override
  Widget build(BuildContext context) {
    final selectedNavIndex = ref.watch(selectedNavIndexProvider);
    final controller = ref.read(measurementControllerProvider);

    // This keeps the broker connection alive for every page.
    ref.watch(mqttConnectionProvider);

    final List<Widget> pages = [
      const LocationViewPage(),
      const PlaybackGroupsPage(),
      const SpeakerSetupPage(),
      const SettingsPageWidget(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          pages[selectedNavIndex],

          // The measurement controls float above the location view.
          if (selectedNavIndex == 0)
            Positioned(
              left: 24,
              right: 24,
              bottom: 110,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Show button here ONLY when NOT connected
                  if (!controller.isConnected)
                    SizedBox(
                      width: double.infinity,
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
                          shadowColor: const Color(
                            0xFFd4af37,
                          ).withValues(alpha: 0.3),
                        ),
                        child: const Text(
                          "START MEASUREMENT",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                    ),

                  const SizedBox(height: 12),

                  // Show distances ONLY when connected
                  if (controller.isConnected)
                    ExpansionTile(
                      shape: Border(),
                      title: const Text(
                        "Distances",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.yellow,
                        ),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _startMeasurement,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFd4af37),
                                foregroundColor: const Color(0xFF0a101f),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                "STOP MEASUREMENT",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                          ),
                        ),

                        const _ConnectedSensorsPanel(),
                      ],
                    ),
                ],
              ),
            ),

          Positioned(
            left: 24,
            right: 24,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
                        icon: Icons.speaker_group,
                        label: 'Playback',
                        index: 1,
                        isSelected: selectedNavIndex == 1,
                        onTap: () {
                          ref.read(selectedNavIndexProvider.notifier).state = 1;
                        },
                      ),
                      _buildNavItem(
                        icon: Icons.speaker,
                        label: 'Speakers',
                        index: 2,
                        isSelected: selectedNavIndex == 2,
                        onTap: () {
                          ref.read(selectedNavIndexProvider.notifier).state = 2;
                        },
                      ),
                      _buildNavItem(
                        icon: Icons.settings,
                        label: 'Settings',
                        index: 3,
                        isSelected: selectedNavIndex == 3,
                        onTap: () {
                          ref.read(selectedNavIndexProvider.notifier).state = 3;
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
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isSelected
                    ? const Color(0xFFd4af37)
                    : const Color(0xFF808080),
                size: 28,
              ),
              const SizedBox(height: 5),
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected
                      ? const Color(0xFFd4af37)
                      : const Color(0xFF808080),
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectedSensorsPanel extends ConsumerWidget {
  const _ConnectedSensorsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final distanceItems = ref.watch(distanceItemsProvider);
    final displayNames = ref.watch(sensorDisplayNamesProvider);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFd4af37).withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'CONNECTED SENSORS',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: const Color(0xFFd4af37).withValues(alpha: 0.8),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: distanceItems.length,
              separatorBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Divider(
                  color: const Color(0xFFd4af37).withValues(alpha: 0.1),
                  height: 1,
                ),
              ),
              itemBuilder: (context, index) {
                final item = distanceItems[index];
                final displayName = sensorDisplayName(displayNames, item);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          abbreviateId(item.id),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (displayName != null)
                        Expanded(
                          child: Text(
                            displayName,
                            style: TextStyle(
                              color: const Color(
                                0xFFd4af37,
                              ).withValues(alpha: 0.8),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        formatDistanceMillimeters(item.distance),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
