import 'dart:convert';
import 'dart:io';
import 'chat.dart';
import 'launcher.dart';
import 'sched.dart';

/// Weather from Open-Meteo (free, no key). Needs internet; everything else in the brief doesn't.
class Weather {
  final double now, max, min;
  final int code, rain;
  final double tmax, tmin; // tomorrow
  final int tcode, train;
  Weather(this.now, this.max, this.min, this.code, this.rain, this.tmax, this.tmin, this.tcode, this.train);

  static Future<Map> _get(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 15));
      final raw = await res.transform(utf8.decoder).join();
      return res.statusCode == 200 ? jsonDecode(raw) as Map : {};
    } finally {
      client.close();
    }
  }

  /// City name → (name, lat, lon), or null.
  static Future<(String, double, double)?> geocode(String city) async {
    try {
      final j = await _get('https://geocoding-api.open-meteo.com/v1/search?count=1&name=${Uri.encodeComponent(city)}');
      final list = j['results'] as List?;
      final r = (list != null && list.isNotEmpty) ? list.first : null;
      if (r is! Map) return null;
      final name = [r['name'], r['admin1'], r['country']].whereType<String>().toSet().join(', ');
      return (name, (r['latitude'] as num).toDouble(), (r['longitude'] as num).toDouble());
    } catch (_) {
      return null;
    }
  }

  static Future<Weather?> fetch() async {
    final la = prefs.lat, lo = prefs.lon;
    if (la == null || lo == null) return null;
    try {
      final j = await _get('https://api.open-meteo.com/v1/forecast?latitude=$la&longitude=$lo'
          '&current=temperature_2m,weather_code'
          '&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code'
          '&timezone=auto&forecast_days=2');
      final cur = j['current'] as Map, d = j['daily'] as Map;
      double n(List l, int i) => (l[i] as num?)?.toDouble() ?? 0;
      int k(List l, int i) => (l[i] as num?)?.toInt() ?? 0;
      return Weather(
        (cur['temperature_2m'] as num).toDouble(),
        n(d['temperature_2m_max'], 0), n(d['temperature_2m_min'], 0),
        (cur['weather_code'] as num).toInt(), k(d['precipitation_probability_max'], 0),
        n(d['temperature_2m_max'], 1), n(d['temperature_2m_min'], 1),
        k(d['weather_code'], 1), k(d['precipitation_probability_max'], 1),
      );
    } catch (_) {
      return null;
    }
  }

  /// WMO weather code → emoji + words.
  static (String, String) describe(int c) {
    if (c == 0) return ('☀️', 'Clear');
    if (c <= 2) return ('🌤️', 'Partly cloudy');
    if (c == 3) return ('☁️', 'Cloudy');
    if (c == 45 || c == 48) return ('🌫️', 'Fog');
    if (c >= 51 && c <= 57) return ('🌦️', 'Drizzle');
    if (c >= 61 && c <= 67) return ('🌧️', 'Rain');
    if (c >= 71 && c <= 77) return ('🌨️', 'Snow');
    if (c >= 80 && c <= 82) return ('🌧️', 'Showers');
    if (c >= 85 && c <= 86) return ('🌨️', 'Snow showers');
    if (c >= 95) return ('⛈️', 'Thunderstorm');
    return ('🌡️', 'Weather');
  }

  Map toCard({bool tomorrow = false}) {
    final (e, w) = describe(tomorrow ? tcode : code);
    return {
      'type': 'weather',
      'city': prefs.city.split(',').first,
      'emoji': e,
      'desc': w,
      'now': tomorrow ? null : now.round(),
      'max': (tomorrow ? tmax : max).round(),
      'min': (tomorrow ? tmin : min).round(),
      'rain': tomorrow ? train : rain,
      'tomorrow': tomorrow,
    };
  }
}

/// Calendar commands: "what's on today", "add dentist on friday at 5".
class CalCmd {
  final String action; // list / add
  final DateTime day;
  final String title;
  final DateTime? at;
  CalCmd(this.action, this.day, {this.title = '', this.at});

  static CalCmd? parse(String input) {
    final t = input.trim();
    final low = Brain.norm(t);
    final listRes = [
      RegExp(r'^(what ?s|what is|whats) (on|planned|happening)( for)? (today|tomorrow)$'),
      RegExp(r'^(what ?s|what is|whats) (on )?(in )?(my )?(calendar|schedule|agenda)( for)?( today| tomorrow)?$'),
      RegExp(r'^(show )?(my )?(calendar|schedule|agenda|events|meetings)( for)?( today| tomorrow)?$'),
      RegExp(r'^(do i have|any) (anything|events?|meetings?|plans)( on| for)?( today| tomorrow)?$'),
    ];
    if (listRes.any((re) => re.hasMatch(low))) {
      final now = DateTime.now();
      final d = low.contains('tomorrow') ? now.add(const Duration(days: 1)) : now;
      return CalCmd('list', DateTime(d.year, d.month, d.day));
    }
    final add = RegExp(r'^(?:please\s+)?(?:add|put|create|schedule|book)\s+(?:an?\s+)?(?:event\s+)?(.+?)(?:\s+(?:to|in|on)\s+(?:my\s+)?calendar)?$',
            caseSensitive: false)
        .firstMatch(t);
    if (add != null) {
      final w = When.find(add.group(1)!);
      if (w == null || w.rest.isEmpty) return null;
      return CalCmd('add', DateTime(w.at.year, w.at.month, w.at.day), title: _cap(w.rest), at: w.at);
    }
    return null;
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

bool isBriefCmd(String input) => RegExp(
        r'^(good morning( vibe)?|morning brief|daily brief|my brief|brief( me)?|my day|how.?s my day( looking)?|what.?s my day( like)?|today.?s brief)\W*$',
        caseSensitive: false)
    .hasMatch(input.trim());

bool isWeatherCmd(String input) =>
    RegExp(r"^(what.?s the |how.?s the |today.?s |tomorrow.?s )?weather( today| tomorrow| now| like)?\??$",
            caseSensitive: false)
        .hasMatch(input.trim());

/// Books the next daily brief (or cancels it).
Future<void> scheduleBrief() async {
  await Native.cancelSched('brief');
  if (!prefs.brief) return;
  final now = DateTime.now();
  var at = DateTime(now.year, now.month, now.day, prefs.briefHour, prefs.briefMinute);
  if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
  await Native.schedule({'id': 'brief', 'type': 'brief', 'at': at.millisecondsSinceEpoch, 'text': 'Daily brief'});
}
