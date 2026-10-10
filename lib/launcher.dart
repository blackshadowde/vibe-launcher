import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One installed app. In the UI it's a "user" in the DM list.
class AppEntry {
  final String label, pkg;
  final Uint8List icon;
  final int category;
  AppEntry(this.label, this.pkg, this.icon, this.category);
}

/// Android side: list apps, launch them, open system screens.
class Native {
  static const _c = MethodChannel('vibe/launcher');
  static VoidCallback? onHomePressed;
  static void Function(Map)? onNotification;

  static void init() {
    _c.setMethodCallHandler((call) async {
      if (call.method == 'homePressed') onHomePressed?.call();
      if (call.method == 'notif' && call.arguments is Map) onNotification?.call(call.arguments as Map);
    });
  }

  static Future<bool> notifAccess() async => await _c.invokeMethod<bool>('notifAccess') ?? false;
  static Future<void> openNotifAccess() => _c.invokeMethod('openNotifAccess');
  static Future<List<Map>> drainNotifs() async => await _c.invokeListMethod<Map>('drainNotifs') ?? [];
  static Future<bool> replyNotif(String key, String text) async =>
      await _c.invokeMethod<bool>('replyNotif', {'key': key, 'text': text}) ?? false;
  static Future<bool> openNotif(String key) async =>
      await _c.invokeMethod<bool>('openNotif', {'key': key}) ?? false;

  static Future<List<AppEntry>> apps() async {
    final raw = await _c.invokeListMethod<Map>('getApps') ?? [];
    return raw
        .map((m) => AppEntry(m['label'] as String, m['package'] as String,
            m['icon'] as Uint8List, (m['category'] as int?) ?? -1))
        .toList();
  }

  static Future<bool> launch(String pkg) async =>
      await _c.invokeMethod<bool>('launch', {'package': pkg}) ?? false;
  static Future<void> openSettings() => _c.invokeMethod('openSettings');
  static Future<void> openAccounts() => _c.invokeMethod('openAccounts');
  static Future<void> openHomeSettings() => _c.invokeMethod('openHomeSettings');
  static Future<void> appInfo(String pkg) => _c.invokeMethod('openAppInfo', {'package': pkg});
  static Future<void> uninstall(String pkg) => _c.invokeMethod('uninstall', {'package': pkg});
  static Future<bool> isDefault() async => await _c.invokeMethod<bool>('isDefaultLauncher') ?? false;
  static Future<Map> deviceInfo() async => await _c.invokeMapMethod('deviceInfo') ?? {};

  /// Opens Android's voice typing and returns what was said (null if cancelled).
  static Future<String?> listen() => _c.invokeMethod<String>('listen');

  static Future<bool> openUrl(String url) async =>
      await _c.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
  static Future<bool> playMusic(String q) async =>
      await _c.invokeMethod<bool>('playMusic', {'query': q}) ?? false;
  static Future<bool> setAlarm(int h, int m, String label) async =>
      await _c.invokeMethod<bool>('setAlarm', {'hour': h, 'minute': m, 'label': label}) ?? false;
  static Future<bool> setTimer(int s, String label) async =>
      await _c.invokeMethod<bool>('setTimer', {'seconds': s, 'label': label}) ?? false;
}

/// "Servers" in the left rail. Built from Android's own app categories.
class Category {
  final String name;
  final IconData icon;
  final Set<int> codes;
  const Category(this.name, this.icon, this.codes);
}

const categories = [
  Category('Social', Icons.forum_rounded, {4}),
  Category('Games', Icons.sports_esports_rounded, {0}),
  Category('Media', Icons.play_circle_fill_rounded, {1, 2, 3}),
  Category('Tools', Icons.handyman_rounded, {5, 6, 7, 8}),
];

enum SortMode { recent, az }

/// Launcher settings, saved on the phone.
class Prefs extends ChangeNotifier {
  late SharedPreferences _p;
  SharedPreferences get sp => _p;
  ThemeMode theme = ThemeMode.dark;
  SortMode sort = SortMode.recent;
  bool haptics = true;
  String name = 'You';
  String geminiKey = '';
  bool showNotifs = true;
  bool aiNotifs = true;
  Set<String> muted = {};
  String geminiModel = '';
  Set<String> hidden = {};
  Map<String, int> lastUsed = {};

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    theme = ThemeMode.values[_p.getInt('theme') ?? ThemeMode.dark.index];
    sort = SortMode.values[_p.getInt('sort') ?? 0];
    haptics = _p.getBool('haptics') ?? true;
    name = _p.getString('name') ?? 'You';
    geminiKey = _p.getString('geminiKey') ?? '';
    showNotifs = _p.getBool('showNotifs') ?? true;
    aiNotifs = _p.getBool('aiNotifs') ?? true;
    muted = (_p.getStringList('muted') ?? []).toSet();
    geminiModel = _p.getString('geminiModel') ?? '';
    hidden = (_p.getStringList('hidden') ?? []).toSet();
    try {
      lastUsed = Map<String, int>.from(jsonDecode(_p.getString('lastUsed') ?? '{}'));
    } catch (_) {}
  }

  void setTheme(ThemeMode m) { theme = m; _p.setInt('theme', m.index); notifyListeners(); }
  void setSort(SortMode m) { sort = m; _p.setInt('sort', m.index); notifyListeners(); }
  void setHaptics(bool v) { haptics = v; _p.setBool('haptics', v); notifyListeners(); }
  void setName(String v) {
    name = v.trim().isEmpty ? 'You' : v.trim();
    _p.setString('name', name);
    notifyListeners();
  }

  void setGeminiKey(String v) { geminiKey = v.trim(); _p.setString('geminiKey', geminiKey); notifyListeners(); }
  void setGeminiModel(String v) { geminiModel = v.trim(); _p.setString('geminiModel', geminiModel); notifyListeners(); }

  void setShowNotifs(bool v) { showNotifs = v; _p.setBool('showNotifs', v); notifyListeners(); }
  void setAiNotifs(bool v) { aiNotifs = v; _p.setBool('aiNotifs', v); notifyListeners(); }
  void toggleMuted(String pkg) {
    muted.contains(pkg) ? muted.remove(pkg) : muted.add(pkg);
    _p.setStringList('muted', muted.toList());
    notifyListeners();
  }

  void toggleHidden(String pkg) {
    hidden.contains(pkg) ? hidden.remove(pkg) : hidden.add(pkg);
    _p.setStringList('hidden', hidden.toList());
    notifyListeners();
  }

  void markUsed(String pkg) {
    lastUsed[pkg] = DateTime.now().millisecondsSinceEpoch;
    _p.setString('lastUsed', jsonEncode(lastUsed));
    notifyListeners();
  }

  void tap() { if (haptics) HapticFeedback.selectionClick(); }
  void heavy() { if (haptics) HapticFeedback.mediumImpact(); }
}

final prefs = Prefs();

String ago(int? ms) {
  if (ms == null) return '';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'Opened just now';
  if (d.inHours < 1) return 'Opened ${d.inMinutes}m ago';
  if (d.inDays < 1) return 'Opened ${d.inHours}h ago';
  if (d.inDays < 7) return 'Opened ${d.inDays}d ago';
  return 'Opened ${(d.inDays / 7).floor()}w ago';
}
