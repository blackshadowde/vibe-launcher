import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'chat.dart';
import 'launcher.dart';

typedef Call = ({String name, Map<String, dynamic> args});
typedef Source = ({String title, String url});

class GeminiResult {
  final String text;
  final List<Call> calls;
  final List<Source> sources;
  final String? error;
  /// 'busy' (overloaded / rate limited) or 'missing' (model not found): worth trying another model
  final String? retry;
  GeminiResult({this.text = '', this.calls = const [], this.sources = const [], this.error, this.retry});
}

/// Talks to Google's Gemini API with the user's own key (stored only on the phone).
class Gemini {
  static const defaultModel = 'gemini-flash-latest';
  static const fallbackModel = 'gemini-flash-lite-latest';
  static bool get enabled => prefs.geminiKey.trim().isNotEmpty;

  static final _tools = [
    {
      'functionDeclarations': [
        _fn('open_app', 'Open an installed app on the phone.',
            {'app_name': _s('App name as the user said it, e.g. "whatsapp"')}, ['app_name']),
        _fn('show_all_apps', 'Slide in the list of all installed apps.', {}, []),
        _fn('open_settings', 'Open phone settings or the launcher\'s own settings.',
            {'target': {'type': 'string', 'enum': ['phone', 'launcher']}}, ['target']),
        _fn('web_search',
            'Search Google for anything current or factual: news, weather, scores, prices, people, places, how-to. '
                'Use this instead of guessing.',
            {'query': _s('Search query')}, ['query']),
        _fn('open_url', 'Open a web page in the browser.', {'url': _s('Full https URL')}, ['url']),
        _fn('play_music', 'Play a song, artist, album or playlist in the phone\'s music player.',
            {'query': _s('What to play')}, ['query']),
        _fn('set_alarm', 'Set an alarm.', {
          'hour': {'type': 'integer', 'description': '0-23'},
          'minute': {'type': 'integer', 'description': '0-59'},
          'label': _s('Optional label'),
        }, ['hour', 'minute']),
        _fn('set_timer', 'Start a countdown timer.', {
          'seconds': {'type': 'integer'},
          'label': _s('Optional label'),
        }, ['seconds']),
        _fn('clear_chat', 'Delete the chat history with Vibe.', {}, []),
        _fn('media_control', 'Control the music that is playing (or was last playing).', {
          'action': {'type': 'string', 'enum': ['play', 'pause', 'next', 'previous']},
        }, ['action']),
        _fn('reply_notification',
            'Reply to a chat notification listed in the context (WhatsApp, Telegram, SMS…). '
                'Only for notifications marked [can reply].',
            {'id': _s('Notification id like "n3"'), 'text': _s('The reply to send')}, ['id', 'text']),
        _fn('open_notification', 'Open the app screen behind a notification listed in the context.',
            {'id': _s('Notification id like "n3"')}, ['id']),
      ]
    }
  ];

  static Map _s(String d) => {'type': 'string', 'description': d};
  static Map _fn(String n, String d, Map props, List<String> req) => {
        'name': n,
        'description': d,
        'parameters': {'type': 'object', 'properties': props, if (req.isNotEmpty) 'required': req},
      };

  static String _system(List<AppEntry> apps, List<Msg> notifs) {
    final now = DateTime.now();
    final names = apps.map((a) => a.label).toList()..sort();
    return 'You are Vibe, a friendly assistant built into the user\'s Android home screen launcher. '
        'The home screen is a Discord-style chat with you. '
        'Keep replies short and natural (1-3 sentences) unless the user asks for detail. '
        'Reply in the same language the user writes in. '
        'When the user wants something done on the phone, call the matching function. '
        'For anything current or factual you are not sure about, call web_search. '
        'If you call a function, you may add a very short message like "Opening WhatsApp" — no more. '
        'Current local time: ${now.toIso8601String()} (${_weekday(now.weekday)}). '
        'User\'s name: ${prefs.name}. '
        'Installed apps: ${names.join(', ')}.'
        '${_music(notifs)}'
        '${_notifBlock(notifs)}';
  }

  static String _music(List<Msg> recent) {
    for (final m in chat.msgs.reversed) {
      if (m.media) {
        return '\nMusic: latest update from ${m.app} at ${stamp(DateTime.fromMillisecondsSinceEpoch(m.ts))}: ${m.text}.';
      }
    }
    return '';
  }

  /// Recent notifications, numbered so Gemini can refer to them (n1 = newest).
  static String _notifBlock(List<Msg> notifs) {
    if (notifs.isEmpty) return '';
    final b = StringBuffer('\n\nRecent notifications on the phone (newest first). '
        'Use them to answer questions like "what did I miss" or "did X message me". '
        'Summarise naturally; don\'t list ids to the user. '
        'Before replying to someone, make sure you picked the right notification:\n');
    for (var i = 0; i < notifs.length; i++) {
      final m = notifs[i];
      final t = DateTime.fromMillisecondsSinceEpoch(m.ts);
      final body = m.text.length > 220 ? '${m.text.substring(0, 220)}…' : m.text;
      b.writeln('n${i + 1} | ${stamp(t)} | ${m.app}${(m.title ?? '').isEmpty ? '' : ' | ${m.title}'} | '
          '$body${m.canReply ? ' [can reply]' : ''}');
    }
    return b.toString();
  }

  static String _weekday(int d) =>
      const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][d - 1];

  /// Recent chat as Gemini turns (text only), merged so roles alternate.
  static List<Map> _history(List<Msg> msgs) {
    final out = <Map>[];
    // Error lines aren't real answers, so leave them out
    final talk = msgs.where((m) => !m.isNotif && !m.error && m.text.trim().isNotEmpty).toList();
    for (final m in talk.length > 16 ? talk.sublist(talk.length - 16) : talk) {
      final role = m.me ? 'user' : 'model';
      final text = m.quote != null ? '(my reply to ${m.quote}) ${m.text}' : m.text;
      if (out.isNotEmpty && out.last['role'] == role) {
        if (role == 'user') {
          // An earlier message that never got an answer: drop it so Gemini answers the newest one
          out[out.length - 1] = {'role': 'user', 'parts': [{'text': text}]};
        } else {
          (out.last['parts'] as List).add({'text': text});
        }
      } else {
        out.add({'role': role, 'parts': [{'text': text}]});
      }
    }
    while (out.isNotEmpty && out.first['role'] != 'user') {
      out.removeAt(0);
    }
    return out;
  }

  /// Main call: Gemini decides to reply and/or call functions.
  static Future<GeminiResult> ask(List<Msg> history, List<AppEntry> apps, List<Msg> notifs) async {
    final body = {
      'systemInstruction': {'parts': [{'text': _system(apps, notifs)}]},
      'contents': _history(history),
      'tools': _tools,
    };
    return _post(body);
  }

  /// Second call for web_search: answer using live Google Search results.
  static Future<GeminiResult> search(String query, String question) async {
    final body = {
      'systemInstruction': {
        'parts': [
          {
            'text': 'You are Vibe, a phone assistant. Answer the user using Google Search. '
                'Be concise: a short paragraph or a few bullets. Reply in the user\'s language. '
                'Current local time: ${DateTime.now().toIso8601String()}.'
          }
        ]
      },
      'contents': [
        {'role': 'user', 'parts': [{'text': question.trim().isEmpty ? query : '$question\n(search: $query)'}]}
      ],
      'tools': [
        {'google_search': {}}
      ],
    };
    return _post(body);
  }

  /// Models your key can use for chat, newest-looking first. Null = couldn't load.
  static Future<List<({String id, String label})>?> listModels() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200'));
      req.headers.set('x-goog-api-key', prefs.geminiKey.trim());
      final res = await req.close().timeout(const Duration(seconds: 20));
      final raw = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final out = <({String id, String label})>[];
      for (final m in (jsonDecode(raw)['models'] as List? ?? [])) {
        if (m is! Map) continue;
        final id = (m['name'] ?? '').toString().replaceFirst('models/', '');
        final methods = (m['supportedGenerationMethods'] as List? ?? []).map((e) => e.toString());
        if (!id.startsWith('gemini') || !methods.contains('generateContent')) continue;
        if (RegExp(r'embedding|tts|image|audio|live|vision|robotics|computer-use|native').hasMatch(id)) continue;
        out.add((id: id, label: (m['displayName'] ?? id).toString()));
      }
      int rank(String id) => id.endsWith('-latest') ? 0 : id.contains('preview') || id.contains('exp') ? 2 : 1;
      out.sort((a, b) {
        final r = rank(a.id).compareTo(rank(b.id));
        return r != 0 ? r : b.id.compareTo(a.id);
      });
      return out;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Tries your model, waits and tries again if it's busy, then falls back to the lighter model.
  static Future<GeminiResult> _post(Map body) async {
    final model = prefs.geminiModel.trim().isEmpty ? defaultModel : prefs.geminiModel.trim();
    final plan = <(String, int)>[
      (model, 0),
      (model, 1500),
      if (model != fallbackModel) (fallbackModel, 0),
    ];
    GeminiResult? last;
    for (final (m, wait) in plan) {
      if (wait > 0) await Future.delayed(Duration(milliseconds: wait));
      final r = await _once(m, body);
      if (r.retry == null) return r;
      if (r.retry == 'missing' && m == fallbackModel && last != null) break;
      if (r.retry == 'missing' && m == model) return r;
      last = r;
    }
    if (last?.retry == 'quota') {
      return GeminiResult(error: 'Gemini\'s free limit is used up for now. Try again in a minute.');
    }
    return GeminiResult(error: 'Gemini is busy right now. Try again in a moment.');
  }

  static Future<GeminiResult> _once(String model, Map body) async {
    final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('x-goog-api-key', prefs.geminiKey.trim());
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close().timeout(const Duration(seconds: 40));
      final raw = await res.transform(utf8.decoder).join();
      Map j = {};
      try {
        j = jsonDecode(raw) as Map;
      } catch (_) {}

      if (res.statusCode != 200) {
        final msg = (j['error'] is Map ? j['error']['message'] : null)?.toString() ?? '';
        if (res.statusCode == 429) return GeminiResult(retry: 'quota');
        if (res.statusCode == 503 || res.statusCode == 500 || res.statusCode == 502 || res.statusCode == 504) {
          return GeminiResult(retry: 'busy');
        }
        if ((res.statusCode == 400 && msg.toLowerCase().contains('api key')) ||
            res.statusCode == 401 ||
            res.statusCode == 403) {
          return GeminiResult(error: 'Your Gemini key isn\'t working. Check it in launcher settings.');
        }
        if (res.statusCode == 404) {
          return GeminiResult(
              retry: 'missing',
              error: 'Gemini model "$model" wasn\'t found. Check the model in launcher settings.');
        }
        return GeminiResult(error: 'Gemini error ${res.statusCode}${msg.isEmpty ? '' : ': $msg'}');
      }

      final cands = j['candidates'] as List? ?? [];
      if (cands.isEmpty) {
        return GeminiResult(error: 'Gemini didn\'t answer that one. Try rephrasing.');
      }
      final cand = cands.first as Map;
      final parts = (cand['content']?['parts'] as List?) ?? [];
      final text = StringBuffer();
      final calls = <Call>[];
      for (final p in parts) {
        if (p is! Map) continue;
        if (p['thought'] == true) continue;
        if (p['text'] is String) text.write(p['text']);
        if (p['functionCall'] is Map) {
          final fc = p['functionCall'] as Map;
          calls.add((
            name: fc['name']?.toString() ?? '',
            args: Map<String, dynamic>.from((fc['args'] as Map?) ?? {}),
          ));
        }
      }
      final sources = <Source>[];
      final chunks = (cand['groundingMetadata']?['groundingChunks'] as List?) ?? [];
      for (final ch in chunks) {
        final w = ch is Map ? ch['web'] : null;
        if (w is Map && w['uri'] != null) {
          sources.add((title: (w['title'] ?? 'Source').toString(), url: w['uri'].toString()));
        }
      }
      return GeminiResult(text: text.toString().trim(), calls: calls, sources: sources.take(5).toList());
    } on SocketException {
      return GeminiResult(error: 'I\'m offline right now. I can still open your apps.');
    } on TimeoutException {
      return GeminiResult(retry: 'busy');
    } on HandshakeException {
      return GeminiResult(error: 'Couldn\'t reach Gemini securely. Check your connection.');
    } on IOException {
      return GeminiResult(retry: 'busy'); // connection dropped mid-way: worth another try
    } catch (e) {
      return GeminiResult(error: 'Something went wrong talking to Gemini (${e.runtimeType}).');
    } finally {
      client.close();
    }
  }
}
