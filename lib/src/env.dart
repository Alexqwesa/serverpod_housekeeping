import 'dart:io';

String envStr(String key, [String def = '']) =>
    (Platform.environment[key]?.trim().isNotEmpty ?? false)
    ? Platform.environment[key]!.trim()
    : def;

int envInt(String key, int def) => int.tryParse(envStr(key, '')) ?? def;

bool envBool(String key, {bool def = false}) {
  final v = envStr(key, '');
  if (v.isEmpty) return def;
  return switch (v.toLowerCase()) {
    '1' || 'true' || 'yes' || 'y' || 'on' => true,
    '0' || 'false' || 'no' || 'n' || 'off' => false,
    _ => def,
  };
}
