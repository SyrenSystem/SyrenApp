import 'package:final_project/communication/mqtt.dart';
import 'package:final_project/serial/serial_base.dart';
import 'package:final_project/ui/location_view_page.dart';
import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

void main() {

  runApp(const MyApp());
}

class DistanceItem {
  final String id;
  double distance;

  DistanceItem({required this.id, required this.distance});
}

class VolumeItem {
  final String id;
  int volume;

  VolumeItem({required this.id, required this.volume});
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

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {

  int _selectedNavViewIndex = 0;
  String _displayTextDistance = "Click Start to start sensor measurement.";
  String _displayTextStartStopSerialButton = "Start";
  Color _colorStartStopSerialButton = Colors.green;
  late MQTTClient _mqttClient;
  final List<DistanceItem> _distanceItems = [];
  final List<VolumeItem> _volumeItems = [];
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  Position3D? _userPosition;
  final Map<String, SpeakerData> _speakers = {};

  Future<void> _saveSettings() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());

    if (ip.isEmpty || port == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a valid IP and port")),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ip', ip);
    await prefs.setInt('port', port);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Settings saved")),
    );
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text = prefs.getString('ip') ?? '';
      _portController.text = prefs.getInt('port')?.toString() ?? '';
    });
  }

  void _addDistanceSensor(DistanceItem item) {
    if (_mqttClient.is_connected())
      {
        _mqttClient.sendSpeakerConnectionInformation(item.id, true);
      }
    setState(() {
      _distanceItems.add(item);
      _volumeItems.add(VolumeItem(id: item.id, volume: 100));
    });
  }

  void _removeDistanceSensor(DistanceItem item) {
    if (_mqttClient.is_connected())
    {
      _mqttClient.sendSpeakerConnectionInformation(item.id, false);
    }
    setState(() {
      _distanceItems.remove(item);
    });
  }

  // initialize the serial connection
  late final SerialConnection _serialConnection = SerialConnection.create((String message){
    try {
      Map<String, dynamic> distanceData = jsonDecode(message);
      _mqttClient.sendDistance(message);
      String id = distanceData["id"];
      double distance = (distanceData["distance"] as num).toDouble();
      print("Distance: ${distanceData['distance']}");
      setState(() {
        _displayTextDistance = "${distanceData["id"]}: ${distanceData['distance']}mm";
      });
      final index = _distanceItems.indexWhere((item) => item.id == id);
      if (index != -1)
      {
        setState(() {
          _distanceItems[index].distance = distance;
        });
      }
      else
        {
          _addDistanceSensor(DistanceItem(id: id, distance: distance));
        }

    }
    catch (e)
    {
      print(e.toString());
    }
  });

  void toggleSerialConnectionButton() {
    setState(() {
      if (_serialConnection.connected) {
        _displayTextStartStopSerialButton = "Stop";
        _colorStartStopSerialButton = Colors.red;
      }
      else {
        _displayTextStartStopSerialButton = "Start";
        _colorStartStopSerialButton = Colors.green;
      }
    });
  }

  @override void initState() {
    super.initState();
    _loadSettings();
    _mqttClient = MQTTClient();

    // Set up MQTT callbacks
    _mqttClient.onUserPositionReceived = (positionData) {
      setState(() {
        _userPosition = Position3D.fromJson(positionData);
      });
    };

    _mqttClient.onSpeakerPositionReceived = (id, positionData) {
      setState(() {
        _speakers[id] = SpeakerData(
          id: id,
          position: Position3D.fromJson(positionData),
        );
      });
    };
  }

  @override
  void dispose() {
    _serialConnection.disconnect();
    _mqttClient.disconnect();
    print("the serial port was closed.");
    super.dispose();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedNavViewIndex = index;
    });
  }


  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      // Location View Page
      LocationViewPage(
        userPosition: _userPosition,
        speakers: _speakers.values.toList(),
        onStartMeasurement: () async {
          if (_serialConnection.connected) {
            List<DistanceItem> toRemoveDistances = List.from(_distanceItems);
            for (DistanceItem item in toRemoveDistances) {
              _removeDistanceSensor(item);
            }
            _serialConnection.disconnect();
            toggleSerialConnectionButton();
            return;
          }

          String ip = _ipController.text.toString();
          int? port = int.tryParse(_portController.text);
          if (ip.isEmpty || port == null) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Invalid MQTT connection preferences.")));
            return;
          }

          if (!_mqttClient.is_connected() && !await _mqttClient.connect(ip, port)) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Could not connect to MQTT.")));
            return;
          }

          final devices = await _serialConnection.getAvailableDevices();
          if (devices.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("No USB sensor detected.")));
            return;
          }

          await _serialConnection.connect(devices.first);
          toggleSerialConnectionButton();
        },
      ),

      // DISTANCE PAGE
      Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              children: [
                ElevatedButton(
                    child: Text(
                      _displayTextStartStopSerialButton,
                      style: TextStyle(color: _colorStartStopSerialButton),
                    ),
                    onPressed: () async {
                      if (_serialConnection.connected)
                        {
                          List<DistanceItem> toRemoveDistances = List.from(_distanceItems);
                          for (DistanceItem item in toRemoveDistances)
                          {
                            _removeDistanceSensor(item);
                          }
                          _serialConnection.disconnect();
                          toggleSerialConnectionButton();
                          return;
                        }

                      String ip = _ipController.text.toString();
                      int? port = int.tryParse(_portController.text);
                      if (ip.isEmpty || port == null)
                        {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Invalid MQTT connection preferences.")));
                          return;
                        }

                      if (!_mqttClient.is_connected() && !await _mqttClient.connect(ip, port))
                        {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Could not connect to MQTT.")));
                          return;
                        }

                      final devices = await _serialConnection.getAvailableDevices();
                      if (devices.isEmpty)
                        {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("No USB sensor detected.")));
                          return;
                        }

                      await _serialConnection.connect(devices.first);
                      toggleSerialConnectionButton();
                    },
                  ),
                Text(_displayTextDistance),
                // Container(
                //   height: 200,
                //   color: Colors.blue
                // )
                Container(
                  height: 300,
                  color: Colors.blue,
                  child: ListView.builder(
                  itemCount: _distanceItems.length,
                  itemBuilder: (context, index) {
                  final item = _distanceItems[index];
                  return ListTile(
                  leading: Text("ID: ${item.id}"),
                  title: Text("Distance: ${item.distance.toStringAsFixed(2)}mm")
                  );
                })
                )
              ],
            ),
          ),
        ],
      ),

      // page volume control
      ListView.builder(
        itemCount: _volumeItems.length,
        itemBuilder: (context, index) {
        final item = _volumeItems[index];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.id),
              Slider(
                  value: item.volume.toDouble(),
                  min: 0,
                max: 100,
                divisions: 100,
                label:(item.volume.toString()),
                onChanged: (double value) {
                    print("volume changed:");
              })
            ],
    );
    }
      ),


      // page settings
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
          pages[_selectedNavViewIndex],
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black..withValues(alpha: 0.3),
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
                    currentIndex: _selectedNavViewIndex,
                    selectedItemColor: const Color(0xFFd4af37),
                    unselectedItemColor: Colors.grey,
                    onTap: _onItemTapped,
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

