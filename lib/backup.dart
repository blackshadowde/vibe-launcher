import 'dart:convert';
import 'chat.dart';
import 'day.dart';
import 'launcher.dart';
import 'memory.dart';

/// Backup & restore: chat, memory, reminders and settings in one file.
/// API keys and the Gmail app password are NOT included (they stay encrypted on this phone).
class Backup {
  static Future<String> export() async {
    final p = prefs.sp;
    final settings = <String, dynamic>{};
    for (final k in p.getKeys()) {
      final v = p.get(k);
      if (v is List) {
        settings[k] = {'list': v.map((e) => '$e').toList()};
      } else {
        settings[k] = v;
      }
    }
    return const JsonEncoder.withIndent(' ').convert({
      'app': 'vibe-launcher',
      'version': 1,
      'created': DateTime.now().toIso8601String(),
      'settings': settings,
      'scheduled': await Native.listSched(),
    });
  }

  /// Returns a short summary, or throws if the file isn't a Vibe backup.
  static Future<String> restore(String text) async {
    final j = jsonDecode(text);
    if (j is! Map || j['app'] != 'vibe-launcher' || j['settings'] is! Map) {
      throw const FormatException('This isn\'t a Vibe backup file.');
    }
    final p = prefs.sp;
    final s = j['settings'] as Map;
    for (final e in s.entries) {
      final k = '${e.key}', v = e.value;
      if (v is bool) {
        await p.setBool(k, v);
      } else if (v is int) {
        await p.setInt(k, v);
      } else if (v is double) {
        await p.setDouble(k, v);
      } else if (v is String) {
        await p.setString(k, v);
      } else if (v is Map && v['list'] is List) {
        await p.setStringList(k, (v['list'] as List).map((e) => '$e').toList());
      }
    }
    var reminders = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final it in (j['scheduled'] as List? ?? [])) {
      if (it is Map && ((it['at'] as num?) ?? 0) > now && it['type'] != 'brief') {
        await Native.schedule(Map<String, dynamic>.from(it));
        reminders++;
      }
    }
    await prefs.load();
    chat.load();
    memory.load();
    if (prefs.brief) await scheduleBrief();
    prefs.refresh();
    return 'Restored ${chat.msgs.length} messages, ${memory.facts.length} memories and $reminders reminders.';
  }
}
