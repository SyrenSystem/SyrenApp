import 'package:final_project/models/system_configuration.dart';
import 'package:flutter/material.dart';

void showCommandFeedback(
  BuildContext context,
  CommandResult? result,
  String successMessage,
) {
  final message = result == null
      ? 'Server did not respond'
      : result.success
      ? successMessage
      : result.error ?? 'Command failed';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
