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
  GeminiResult({this.text = '', this.calls = const [], this.sources = const [], this.error});
}

/// Talks to Google's Gemini API with the user's own key (stored only on the phone).
class Gemini {
  static const defaultModel = 'gemini-flash-latest';
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
      ]
    }
  ];

  static Map _s(String d) => {'type': 'string', 'description': d};
  static Map _fn(String n, String d, Map props, List<String> req) => {
        'name': n,
        'description': d,
        'parameters': {'type': 'object', 'properties': props, if (req.isNotEmpty) 'required': req},
      };

  static String _system(List<AppEntry> apps) {
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
        'Installed apps: ${names.join(', ')}.';
  }

  static String _weekday(int d) =>
      const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][d - 1];

  /// Recent chat as Gemini turns (text only), merged so roles alternate.
  static List<Map> _history(List<Msg> msgs) {
    final out = <Map>[];
    for (final m in msgs.length > 16 ? msgs.sublist(msgs.length - 16) : msgs) {
      if (m.text.trim().isEmpty) continue;
      final role = m.me ? 'user' : 'model';
      if (out.isNotEmpty && out.last['role'] == role) {
        (out.last['parts'] as List).add({'text': m.text});
      } else {
        out.add({'role': role, 'parts': [{'text': m.text}]});
      }
    }
    while (out.isNotEmpty && out.first['role'] != 'user') {
      out.removeAt(0);
    }
    return out;
  }

  /// Main call: Gemini decides to reply and/or call functions.
  static Future<GeminiResult> ask(List<Msg> history, List<AppEntry> apps) async {
    final body = {
      'systemInstruction': {'parts': [{'text': _system(apps)}]},
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

  static Future<GeminiResult> _post(Map body) async {
    final model = prefs.geminiModel.trim().isEmpty ? defaultModel : prefs.geminiModel.trim();
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
        if (res.statusCode == 429) {
          return GeminiResult(error: 'Gemini\'s free limit is used up for now. Try again in a minute.');
        }
        if ((res.statusCode == 400 && msg.toLowerCase().contains('api key')) ||
            res.statusCode == 401 ||
            res.statusCode == 403) {
          return GeminiResult(error: 'Your Gemini key isn\'t working. Check it in launcher settings.');
        }
        if (res.statusCode == 404) {
          return GeminiResult(error: 'Gemini model "$model" wasn\'t found. Check the model in launcher settings.');
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
      return GeminiResult(error: 'Gemini took too long to answer. Try again.');
    } on HandshakeException {
      return GeminiResult(error: 'Couldn\'t reach Gemini securely. Check your connection.');
    } catch (e) {
      return GeminiResult(error: 'Something went wrong talking to Gemini.');
    } finally {
      client.close();
    }
  }
}
