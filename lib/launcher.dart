import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';

/// One installed app. In the UI it's a "user" in the DM list.
/// Shown in settings and when you ask "what version is this".
const vibeVersion = '0.20.0';

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
  static void Function(Map)? onShared;
  static void Function(Map)? onFired;
  static void Function(bool)? onNet;
  static void Function(int done, int total)? onNanoProgress;

  static void init() {
    _c.setMethodCallHandler((call) async {
      if (call.method == 'homePressed') onHomePressed?.call();
      if (call.method == 'notif' && call.arguments is Map) onNotification?.call(call.arguments as Map);
      if (call.method == 'shared' && call.arguments is Map) onShared?.call(call.arguments as Map);
      if (call.method == 'fired' && call.arguments is Map) onFired?.call(call.arguments as Map);
      if (call.method == 'net') onNet?.call(call.arguments == true);
      if (call.method == 'nanoProgress' && call.arguments is Map) {
        final m = call.arguments as Map;
        onNanoProgress?.call((m['done'] as num?)?.toInt() ?? 0, (m['total'] as num?)?.toInt() ?? 0);
      }
    });
  }

  static Future<bool> notifAccess() async => await _c.invokeMethod<bool>('notifAccess') ?? false;
  static Future<void> openNotifAccess() => _c.invokeMethod('openNotifAccess');
  static Future<List<Map>> drainNotifs() async => await _c.invokeListMethod<Map>('drainNotifs') ?? [];
  static Future<bool> replyNotif(String key, String text) async =>
      await _c.invokeMethod<bool>('replyNotif', {'key': key, 'text': text}) ?? false;
  static Future<bool> mediaControl(String? pkg, String action) async =>
      await _c.invokeMethod<bool>('mediaControl', {'package': pkg, 'action': action}) ?? false;
  // Reminders & scheduled messages
  static Future<bool> schedule(Map item) async => await _c.invokeMethod<bool>('schedule', item) ?? false;
  static Future<void> cancelSched(String id) => _c.invokeMethod('cancelSched', {'id': id});
  static Future<List<Map>> listSched() async => await _c.invokeListMethod<Map>('listSched') ?? [];
  static Future<List<Map>> takeFired() async => await _c.invokeListMethod<Map>('takeFired') ?? [];
  static Future<void> requestPostNotif() => _c.invokeMethod('requestPostNotif');

  static Future<bool> online() async => await _c.invokeMethod<bool>('online') ?? true;

  /// Why Vibe closed last time, if it crashed (read once, then forgotten).
  static Future<String?> lastCrash() async {
    try {
      return await _c.invokeMethod<String>('lastCrash');
    } catch (_) {
      return null;
    }
  }

  // Icon packs
  static Future<List<Map>> iconPacks() async => await _c.invokeListMethod<Map>('iconPacks') ?? [];

  // Global search
  static Future<List<Map>> searchSms(String q) async => await _c.invokeListMethod<Map>('searchSms', {'q': q}) ?? [];
  static Future<List<Map>> searchFiles(String q) async => await _c.invokeListMethod<Map>('searchFiles', {'q': q}) ?? [];
  static Future<List<Map>> searchEvents(String q) async =>
      await _c.invokeListMethod<Map>('searchEvents', {'q': q}) ?? [];
  static Future<void> openFile(String uri, String mime) => _c.invokeMethod('openFile', {'uri': uri, 'mime': mime});
  static Future<Map> searchPerms() async => await _c.invokeMapMethod('searchPerms') ?? {};
  static Future<void> requestSms() => _c.invokeMethod('requestSms');
  static Future<void> requestFiles() => _c.invokeMethod('requestFiles');

  // Pictures
  static Future<String?> saveToGallery(String path) => _c.invokeMethod<String>('saveToGallery', {'path': path});
  static Future<void> shareImage(String uri) => _c.invokeMethod('shareImage', {'uri': uri});
  static Future<bool> setWallpaper(String path, {bool lockOnly = false}) async =>
      await _c.invokeMethod<bool>('setWallpaper', {'path': path, 'lock': lockOnly}) ?? false;

  // Backup & restore through Android's file picker
  static Future<bool> saveDoc(String name, String text) async =>
      await _c.invokeMethod<bool>('saveDoc', {'name': name, 'text': text}) ?? false;
  static Future<String?> openDoc() => _c.invokeMethod<String>('openDoc');

  // On-phone AI (Gemini Nano)
  static Future<String> nanoStatus() async => await _c.invokeMethod<String>('nanoStatus') ?? 'unavailable';
  static Future<bool> nanoDownload() async => await _c.invokeMethod<bool>('nanoDownload') ?? false;
  static Future<String?> nanoAsk(String prompt, {String? image}) =>
      _c.invokeMethod<String>('nanoAsk', {'prompt': prompt, 'image': image});

  // Calendar
  static Future<bool> calPerms() async => await _c.invokeMethod<bool>('calPerms') ?? false;
  static Future<void> requestCalendar() => _c.invokeMethod('requestCalendar');
  static Future<List<Map>> events(DateTime from, DateTime to) async =>
      await _c.invokeListMethod<Map>(
          'events', {'from': from.millisecondsSinceEpoch, 'to': to.millisecondsSinceEpoch}) ??
      [];
  static Future<String> addEvent(String title, DateTime begin, DateTime end,
          {bool allDay = false, String location = ''}) async =>
      await _c.invokeMethod<String>('addEvent', {
        'title': title,
        'begin': begin.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
        'allDay': allDay,
        'location': location,
      }) ??
      'failed';
  static Future<void> openEvent(int id) => _c.invokeMethod('openEvent', {'id': id});

  static Future<Map?> takeShared() => _c.invokeMapMethod('takeShared');
  static Future<String> filesDir() async => await _c.invokeMethod<String>('filesDir') ?? '';

  // People
  static Future<Map> peoplePerms() async => await _c.invokeMapMethod('peoplePerms') ?? {};
  static Future<Map> requestPeople() async => await _c.invokeMapMethod('requestPeople') ?? {};
  static Future<List<Map>> contacts() async => await _c.invokeListMethod<Map>('contacts') ?? [];
  static Future<Uint8List?> contactPhoto(String id) => _c.invokeMethod<Uint8List>('contactPhoto', {'id': id});
  static Future<List<Map>> callLog(int limit) async =>
      await _c.invokeListMethod<Map>('callLog', {'limit': limit}) ?? [];
  static Future<bool> call(String number) async =>
      await _c.invokeMethod<bool>('call', {'number': number}) ?? false;
  static Future<bool> sendSms(String number, String text) async =>
      await _c.invokeMethod<bool>('sendSms', {'number': number, 'text': text}) ?? false;
  static Future<bool> smsApp(String number, String text) async =>
      await _c.invokeMethod<bool>('smsApp', {'number': number, 'text': text}) ?? false;
  static Future<bool> whatsapp(String number, String text) async =>
      await _c.invokeMethod<bool>('whatsapp', {'number': number, 'text': text}) ?? false;

  static Future<bool> openNotif(String key) async =>
      await _c.invokeMethod<bool>('openNotif', {'key': key}) ?? false;

  static Future<List<AppEntry>> apps() async {
    final raw = await _c.invokeListMethod<Map>('getApps', {'iconPack': prefs.iconPack}) ?? [];
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

  static Future<bool> openUrl(String url, {String? pkg}) async =>
      await _c.invokeMethod<bool>('openUrl', {'url': url, 'package': pkg}) ?? false;
  static Future<bool> openSettingsPage(String action) async =>
      await _c.invokeMethod<bool>('openSettingsPage', {'action': action}) ?? false;
  static Future<bool> playMusic(String q, {String? pkg}) async =>
      await _c.invokeMethod<bool>('playMusic', {'query': q, 'package': pkg}) ?? false;
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
  /// API keys live in Android's encrypted Keystore storage, not in plain settings.
  static const _vault = FlutterSecureStorage();

  /// Reads one key from the vault, never waiting more than 3 seconds (right after an update
  /// Android's keystore can be slow or broken; the home screen must still appear).
  static Future<String> _secret(String k) async {
    try {
      return await _vault.read(key: k).timeout(const Duration(seconds: 3)) ?? '';
    } catch (_) {
      return '';
    }
  }
  String geminiKey = '';
  String routerKey = ''; // OpenRouter, the backup when Gemini is busy
  String groqKey = ''; // Groq (free): OpenAI's open gpt-oss model, very fast
  String groqModel = '';
  bool cfChat = true; // also chat through Cloudflare when its keys are set
  String mainAi = 'gemini'; // gemini, groq or cloudflare
  List<String> routerModels = []; // free models picked from OpenRouter's list
  int routerModelsAt = 0;
  bool showNotifs = true;
  bool aiNotifs = true;
  bool showMedia = true;
  String messenger = 'whatsapp'; // default for "message X": whatsapp or sms
  bool brief = false;
  bool offlineMode = false; // never use internet
  // Look & feel
  int accent = 0xFF5865F2;
  String wallpaper = ''; // picture behind the chat
  int wallDim = 1; // 0 light, 1 medium, 2 strong
  bool compact = false; // tighter message spacing
  String iconPack = ''; // package of an installed icon pack
  bool roundIcons = true; // clip app icons into circles
  // Gmail (optional, IMAP with an app password)
  String gmailUser = '';
  String gmailPass = '';
  // Pictures (Cloudflare Workers AI, free daily quota)
  String cfAccount = '';
  String cfToken = '';
  List<int> queue = []; // timestamps of your questions waiting for internet
  int briefHour = 7, briefMinute = 30;
  String city = '';
  double? lat, lon;
  int lastBrief = 0;
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
    // Keys: read from the encrypted vault; move any old plain-text key into it
    try {
      geminiKey = await _secret('geminiKey');
      routerKey = await _secret('routerKey');
      groqKey = await _secret('groqKey');
      final old = _p.getString('geminiKey');
      if (old != null) {
        if (geminiKey.isEmpty && old.isNotEmpty) {
          geminiKey = old;
          await _vault.write(key: 'geminiKey', value: old);
        }
        await _p.remove('geminiKey');
      }
    } catch (_) {
      geminiKey = _p.getString('geminiKey') ?? '';
    }
    routerModels = _p.getStringList('routerModels') ?? [];
    groqModel = _p.getString('groqModel') ?? '';
    cfChat = _p.getBool('cfChat') ?? true;
    mainAi = _p.getString('mainAi') ?? 'gemini';
    if (!const ['gemini', 'groq', 'cloudflare'].contains(mainAi)) mainAi = 'gemini';
    routerModelsAt = _p.getInt('routerModelsAt') ?? 0;
    showNotifs = _p.getBool('showNotifs') ?? true;
    aiNotifs = _p.getBool('aiNotifs') ?? true;
    showMedia = _p.getBool('showMedia') ?? true;
    messenger = _p.getString('messenger') ?? 'whatsapp';
    brief = _p.getBool('brief') ?? false;
    offlineMode = _p.getBool('offlineMode') ?? false;
    accent = _p.getInt('accent') ?? 0xFF5865F2;
    VC.accent = Color(accent);
    wallpaper = _p.getString('wallpaper') ?? '';
    wallDim = _p.getInt('wallDim') ?? 1;
    compact = _p.getBool('compact') ?? false;
    iconPack = _p.getString('iconPack') ?? '';
    roundIcons = _p.getBool('roundIcons') ?? true;
    gmailUser = _p.getString('gmailUser') ?? '';
    cfAccount = _p.getString('cfAccount') ?? '';
    try {
      cfToken = await _secret('cfToken');
    } catch (_) {}
    try {
      gmailPass = await _secret('gmailPass');
    } catch (_) {}
    queue = (_p.getStringList('queue') ?? []).map(int.parse).toList();
    briefHour = _p.getInt('briefHour') ?? 7;
    briefMinute = _p.getInt('briefMinute') ?? 30;
    city = _p.getString('city') ?? '';
    lat = _p.getDouble('lat');
    lon = _p.getDouble('lon');
    lastBrief = _p.getInt('lastBrief') ?? 0;
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

  void setGeminiKey(String v) {
    geminiKey = v.trim();
    _vault.write(key: 'geminiKey', value: geminiKey).catchError((_) {});
    notifyListeners();
  }

  void setGroqKey(String v) {
    groqKey = v.trim();
    _vault.write(key: 'groqKey', value: groqKey).catchError((_) {});
    notifyListeners();
  }

  void setGroqModel(String v) { groqModel = v.trim(); _p.setString('groqModel', groqModel); notifyListeners(); }
  void setCfChat(bool v) { cfChat = v; _p.setBool('cfChat', v); notifyListeners(); }
  void setMainAi(String v) { mainAi = v; _p.setString('mainAi', v); notifyListeners(); }

  void setRouterKey(String v) {
    routerKey = v.trim();
    _vault.write(key: 'routerKey', value: routerKey).catchError((_) {});
    routerModels = [];
    notifyListeners();
  }

  void setRouterModels(List<String> m) {
    routerModels = m;
    routerModelsAt = DateTime.now().millisecondsSinceEpoch;
    _p.setStringList('routerModels', m);
    _p.setInt('routerModelsAt', routerModelsAt);
  }
  void setGeminiModel(String v) { geminiModel = v.trim(); _p.setString('geminiModel', geminiModel); notifyListeners(); }

  void setShowNotifs(bool v) { showNotifs = v; _p.setBool('showNotifs', v); notifyListeners(); }
  void setAccent(int v) { accent = v; VC.accent = Color(v); _p.setInt('accent', v); notifyListeners(); }
  void setWallpaper(String path) { wallpaper = path; _p.setString('wallpaper', path); notifyListeners(); }
  void setWallDim(int v) { wallDim = v; _p.setInt('wallDim', v); notifyListeners(); }
  void setCompact(bool v) { compact = v; _p.setBool('compact', v); notifyListeners(); }
  void setIconPack(String v) { iconPack = v; _p.setString('iconPack', v); notifyListeners(); }
  void setRoundIcons(bool v) { roundIcons = v; _p.setBool('roundIcons', v); notifyListeners(); }
  void setCloudflare(String account, String token) {
    cfAccount = account.trim();
    cfToken = token.trim();
    _p.setString('cfAccount', cfAccount);
    _vault.write(key: 'cfToken', value: cfToken).catchError((_) {});
    notifyListeners();
  }

  void setGmail(String user, String pass) {
    gmailUser = user.trim();
    gmailPass = pass.replaceAll(' ', '').trim();
    _p.setString('gmailUser', gmailUser);
    _vault.write(key: 'gmailPass', value: gmailPass).catchError((_) {});
    notifyListeners();
  }

  void setOfflineMode(bool v) { offlineMode = v; _p.setBool('offlineMode', v); notifyListeners(); }
  void setQueue(List<int> q) { queue = q; _p.setStringList('queue', q.map((e) => '$e').toList()); notifyListeners(); }

  void setBrief(bool v, {int? hour, int? minute}) {
    brief = v;
    briefHour = hour ?? briefHour;
    briefMinute = minute ?? briefMinute;
    _p.setBool('brief', v);
    _p.setInt('briefHour', briefHour);
    _p.setInt('briefMinute', briefMinute);
    notifyListeners();
  }

  void setCity(String name, double? la, double? lo) {
    city = name;
    lat = la;
    lon = lo;
    _p.setString('city', name);
    la == null ? _p.remove('lat') : _p.setDouble('lat', la);
    lo == null ? _p.remove('lon') : _p.setDouble('lon', lo);
    notifyListeners();
  }

  void markBrief() { lastBrief = DateTime.now().millisecondsSinceEpoch; _p.setInt('lastBrief', lastBrief); }

  void setMessenger(String v) { messenger = v; _p.setString('messenger', v); notifyListeners(); }
  void setShowMedia(bool v) { showMedia = v; _p.setBool('showMedia', v); notifyListeners(); }
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

  void refresh() => notifyListeners();

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

/// Errors caught while Vibe keeps running; the home screen shows them in chat so they can be reported.
final appErrors = ValueNotifier<String?>(null);
final _seenErrors = <String>{};
void noteError(Object e, StackTrace? st, {String? during}) {
  try {
    var first = e.runtimeType.toString();
    try {
      first = '$e'.split('\n').first;
    } catch (_) {}
    if (first.length > 300) first = '${first.substring(0, 300)}…';
    if (!_seenErrors.add(first)) return;
    final lines = '$st'.split('\n');
    var where = lines.where((l) => l.contains('package:vibe_launcher')).take(4).join('\n');
    if (where.isEmpty) where = lines.take(4).join('\n'); // no Vibe line: show where Flutter was
    final d = during ?? '';
    final ctx = d.isEmpty ? '' : '\n(${d.length > 150 ? d.substring(0, 150) : d})';
    appErrors.value = '$first$ctx${where.trim().isEmpty ? '' : '\n$where'}';
  } catch (_) {}
}
