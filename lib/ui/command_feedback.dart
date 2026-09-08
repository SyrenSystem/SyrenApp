import 'package:final_project/ui/app_feedback.dart';
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
  showLatestSnackBar(context, SnackBar(content: Text(message)));
}
