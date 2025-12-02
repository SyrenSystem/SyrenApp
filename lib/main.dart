import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:final_project/ui/location_view_page.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/providers/measurement_provider.dart';

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
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
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

    if (ip.isEmpty || port == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please enter a valid IP and port")),
        );
      }
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ip', ip);
    await prefs.setInt('port', port);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Settings saved")),
      );
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text = prefs.getString('ip') ?? '';
      _portController.text = prefs.getInt('port')?.toString() ?? '';
    });
  }

  Future<void> _startMeasurement() async {
    final controller = ref.read(measurementControllerProvider);

    if (controller.isConnected) {
      controller.stopMeasurement();
      setState(() {}); // Rebuild to update button text
      return;
    }

    final ip = _ipController.text.toString();
    final port = int.tryParse(_portController.text);

    if (ip.isEmpty || port == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Invalid MQTT connection preferences.")));
      }
      return;
    }

    final error = await controller.startMeasurement(ip, port);
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

    final List<Widget> pages = [
      // Location View Page
      LocationViewPage(
        userPosition: userPosition,
        speakers: speakers.values.toList(),
      ),

      // Distance Debug Page
      Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView.builder(
          itemCount: distanceItems.length,
          itemBuilder: (context, index) {
            final item = distanceItems[index];
            return Card(
              child: ListTile(
                leading: const Icon(Icons.speaker),
                title: Text("ID: ${item.id}"),
                subtitle: Text("Distance: ${item.distance.toStringAsFixed(2)}mm"),
              ),
            );
          },
        ),
      ),

      // Volume Control Page
      Padding(
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
                      "Speaker ${item.id}",
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
                        ref.read(volumeItemsProvider.notifier).updateVolume(
                              item.id,
                              value.toInt(),
                            );
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),

      // Settings Page
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Connection Settings",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: "IP Address",
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: "Port",
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _saveSettings,
              child: const Text("Save"),
            ),
          ],
        ),
      )
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
              bottom: 180,
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
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                border: Border(
                  top: BorderSide(
                    color: const Color(0xFFd4af37).withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BottomNavigationBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    type: BottomNavigationBarType.fixed,
                    items: const [
                      BottomNavigationBarItem(
                        icon: Icon(Icons.social_distance),
                        label: 'Distance',
                      ),
                      BottomNavigationBarItem(
                        icon: Icon(Icons.volume_up_rounded),
                        label: 'Volume',
                      ),
                      BottomNavigationBarItem(
                        icon: Icon(Icons.settings),
                        label: 'Settings',
                      ),
                    ],
                    currentIndex: selectedNavIndex,
                    selectedItemColor: const Color(0xFFd4af37),
                    unselectedItemColor: Colors.grey,
                    onTap: (index) {
                      ref.read(selectedNavIndexProvider.notifier).state = index;
                    },
                  ),
                  Container(
                    width: 128,
                    height: 4,
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade600,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
