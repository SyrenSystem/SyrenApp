import 'dart:convert';

import 'package:flutter/services.dart';

/// Reads the installed version from the Flutter bundle.
Future<String> loadAppVersion() => rootBundle
    .loadString('version.json')
    .then((value) {
      final metadata = jsonDecode(value) as Map<String, dynamic>;
      return 'Version ${metadata['version']}';
    })
    .catchError((Object error) => 'Version unavailable');
