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

  late SerialPort _serialPort;

  int _selectedIndex = 0;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    // final ports = SerialPort.availablePorts;
    // print('Available ports: $ports');
    //
    // _serialPort = SerialPort(ports.first);
    // if (!_serialPort.openRead()) {
    //   print('failed to open port');
    // }
    //
    // final config = SerialPortConfig();
    // config.baudRate = 115200;
    // config.bits = 8;
    // config.stopBits = 1;
    // config.parity = 0;
    // _serialPort.config = config;
    //
    // final reader = SerialPortReader(_serialPort);
    // String buffer = '';
    //
    // reader.stream.listen((data) {
    //   final text = String.fromCharCodes(data);
    //   buffer += text;
    //   if (buffer.contains("\r\n")) {
    //     print("received: $buffer");
    //     buffer = '';
    //   }
    // });
  }

  @override
  void dispose() {
    _serialPort.close();
    print("the serial port was closed.");
    super.dispose();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
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
            child: Stack(
              alignment: Alignment.center,
              children: [

                ElevatedButton(
                    child: Text(
                      'M',
                      style: TextStyle(color: Colors.white),
                    ),
                    onPressed: () async {
                      print("TEST from button m");
                        List<UsbDevice> devices = await UsbSerial.listDevices();
                        print(devices);

                        UsbPort? port;
                        if (devices.length == 0) {
                          return;
                        }
                        port = await devices[0].create();

                        if (port != null)
                          {
                            bool openResult = await port.open();
                            if ( !openResult ) {
                              print("Failed to open");
                              return;
                            }

                            await port.setDTR(true);
                            await port.setRTS(true);

                            port.setPortParameters(115200, UsbPort.DATABITS_8,
                                UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

                            // print first result and close port.
                            port.inputStream!.listen((Uint8List event) {
                              String text = utf8.decode(event);
                              print(text);
                            });
                            Timer (const Duration(seconds: 5), (){
                              port!.close();
                            });
                          }

                    },
                  )

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
      body: pages[_selectedIndex],
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
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.deepPurple,
        onTap: _onItemTapped,
      ),
    );
  }
}
