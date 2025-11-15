import 'package:final_project/serial/serial_desktop.dart';
import 'package:final_project/serial/serial_base.dart';
import 'package:flutter/material.dart';
import 'dart:math';
import 'package:libserialport/libserialport.dart';
import 'package:usb_serial/usb_serial.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';

void main() {

  runApp(const MyApp());
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

  // initialize the serial connection
  late SerialConnection _serialConnection = SerialConnection.create((String message){
    try {
      Map<String, dynamic> distanceData = jsonDecode(message);
      print("Distance: ${distanceData['distance']}");
      setState(() {
        _displayTextDistance = "Distance: ${distanceData['distance']}";
      });
    }
    catch (e)
    {
      print("Error parsing JSON.");
    }
  });

  int _selectedNavViewIndex = 0;
  bool _isPlaying = false;
  String _displayTextDistance = "Click Start to start sensor measurement.";
  String _displayTextStartStopSerialButton = "Start";
  Color _colorStartStopSerialButton = Colors.green;

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

  @override
  void dispose() {
    _serialConnection.disconnect();
    print("the serial port was closed.");
    super.dispose();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedNavViewIndex = index;
    });
  }

  void _togglePlayPause() {
    setState(() {
      _isPlaying = !_isPlaying;
    });
  }

  // Pool of Dutch song names
  final List<String> _dutchSongs = [
    "Het is een Nacht",
    "Zij Gelooft in Mij",
    "Ik Leef Niet Meer voor Jou",
    "Bloed, Zweet en Tranen",
    "Iedereen is van de Wereld",
    "Pastorale",
    "Avond",
    "15 Miljoen Mensen",
    "Dromen Zijn Bedrog",
    "Als de Morgen is Gekomen",
    "Zeg Maar Niets Meer",
    "Suzanne",
    "Vivo per Lei (NL versie)",
    "Leef",
    "Mag Ik Dan Bij Jou",
    "Ik Kan Het Niet Alleen",
    "Oerend Hard",
    "De Vlieger",
    "Laat Me",
    "Het Land van Maas en Waal",
  ];

  late final List<String> _libraryTitles = List.generate(
    30,
    (index) => _dutchSongs[Random().nextInt(_dutchSongs.length)],
  );

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      // PLAYING PAGE
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
                          _serialConnection.disconnect();
                          toggleSerialConnectionButton();
                          return;
                        }

                      final devices = await _serialConnection.getAvailableDevices();
                      await _serialConnection.connect(devices.first);
                      toggleSerialConnectionButton();
                    },
                  ),
                Text(_displayTextDistance)

                // Positioned(
                //   top: 40,
                //   left: MediaQuery.of(context).size.width / 2 - 20,
                //   child: const Icon(
                //     Icons.music_note,
                //     size: 40,
                //     color: Colors.red,
                //   ),
                // ),
                // Positioned(
                //   bottom: 120,
                //   left: 40,
                //   child: const Icon(
                //     Icons.music_note,
                //     size: 40,
                //     color: Colors.red,
                //   ),
                // ),
                // Positioned(
                //   bottom: 50,
                //   right: 40,
                //   child: const Icon(
                //     Icons.music_note,
                //     size: 40,
                //     color: Colors.red,
                //   ),
                // ),
                // Container(
                //   width: 40,
                //   height: 40,
                //   decoration: const BoxDecoration(
                //     color: Colors.blue,
                //     shape: BoxShape.circle,
                //   ),
                // ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous, size: 40),
                  onPressed: () {},
                ),
                IconButton(
                  icon: Icon(
                    _isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    size: 50,
                  ),
                  onPressed: _togglePlayPause,
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next, size: 40),
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ],
      ),

      // LIBRARY PAGE with scrollable list of Dutch songs
      ListView.builder(
        itemCount: _libraryTitles.length,
        itemBuilder: (context, index) {
          return ListTile(
            leading: const Icon(Icons.music_note, color: Colors.deepPurple),
            title: Text(_libraryTitles[index]),
            onTap: () {
              // TODO: handle tapping a track
            },
          );
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text("Syren App"),
        centerTitle: true,
        backgroundColor: Colors.deepPurple,
      ),
      body: pages[_selectedNavViewIndex],
      bottomNavigationBar: BottomNavigationBar(
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.play_circle_fill),
            label: 'Playing',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music),
            label: 'Library',
          ),
        ],
        currentIndex: _selectedNavViewIndex,
        selectedItemColor: Colors.deepPurple,
        onTap: _onItemTapped,
      ),
    );
  }
}

