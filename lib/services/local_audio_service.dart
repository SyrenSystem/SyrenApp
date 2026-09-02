import 'dart:io';

typedef AudioControlRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class LocalAudioService {
  LocalAudioService({
    AudioControlRunner? runner,
    bool? available,
    String? fallbackExecutable,
  }) : _runner = runner ?? Process.run,
       available = available ?? Platform.isLinux,
       _fallbackExecutable =
           fallbackExecutable ??
           '${Platform.environment['HOME']}/.local/bin/syren-audio-control';

  static const _executable = 'syren-audio-control';

  final AudioControlRunner _runner;
  final String _fallbackExecutable;
  final bool available;

  Future<bool?> status() async {
    if (!available) {
      return null;
    }
    try {
      final result = await _run(['status']);
      if (result.exitCode != 0) {
        return null;
      }
      return result.stdout.toString().trim() == 'enabled';
    } on ProcessException {
      return null;
    }
  }

  Future<bool> setEnabled(bool enabled) async {
    if (!available) {
      return false;
    }
    try {
      final result = await _run([enabled ? 'enable' : 'disable']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  Future<ProcessResult> _run(List<String> arguments) async {
    try {
      return await _runner(_executable, arguments);
    } on ProcessException {
      return _runner(_fallbackExecutable, arguments);
    }
  }
}
