import 'package:flutter/material.dart';

void showLatestSnackBar(BuildContext context, SnackBar message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(message);
}
