import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'chat.dart';
import 'launcher.dart';
import 'memory.dart';
import 'privacy.dart';

typedef Call = ({String name, Map<String, dynamic> args});
typedef Source = ({String title, String url});

class GeminiResult {
  final String text;
  final List<Call> calls;
  final List<Source> sources;
  final String? error;
  /// 'busy' (overloaded / rate limited) or 'missing' (model not found): worth trying another model
  final String? retry;
  final String via; // gemini or openrouter
  GeminiResult(
      {this.text = '', this.calls = const [], this.sources = const [], this.error, this.retry, this.via = 'gemini'});
}

/// Talks to Google's Gemini API with the user's own key (stored only on the phone).
class Gemini {
  static const defaultModel = 'gemini-flash-latest';
  static const fallbackModel = 'gemini-flash-lite-latest';
  static bool get enabled => prefs.geminiKey.trim().isNotEmpty || prefs.routerKey.trim().isNotEmpty;

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
        _fn('call_person', 'Phone call to someone in the user\'s contacts.',
            {'name': _s('Contact name as the user said it, e.g. "mom" or "Ravi"')}, ['name']),
        _fn('message_person',
            'Send a message to someone in the user\'s contacts (WhatsApp or SMS). '
                'Write the message text the way the user would, in their language.',
            {
              'name': _s('Contact name as the user said it'),
              'text': _s('The message to send. Empty to just open the chat'),
              'via': {'type': 'string', 'enum': ['whatsapp', 'sms', 'default']},
            },
            ['name']),
        _fn('recent_calls', 'Show recent and missed phone calls.', {}, []),
        _fn('daily_brief', 'Show the user\'s daily brief: weather, calendar, reminders, missed calls, messages.', {}, []),
        _fn('weather', 'Show the weather for the user\'s saved city (only if they haven\'t named another place).',
            {'day': {'type': 'string', 'enum': ['today', 'tomorrow']}}, ['day']),
        _fn('list_events', 'Show calendar events for a day.',
            {'date': _s('Local date in ISO 8601, e.g. 2026-10-11')}, ['date']),
        _fn('add_event', 'Add an event to the phone\'s calendar.', {
          'title': _s('Event title'),
          'start': _s('Local start date-time, ISO 8601 without timezone'),
          'end': _s('Optional local end date-time, ISO 8601'),
          'location': _s('Optional place'),
        }, ['title', 'start']),
        _fn('set_reminder', 'Set a reminder that pings the user at a time.', {
          'text': _s('What to remind about, short, e.g. "Call mom"'),
          'time': _s('Local date-time in ISO 8601 without timezone, e.g. 2026-10-10T18:00:00'),
        }, ['text', 'time']),
        _fn('schedule_message',
            'Schedule a message to someone in the contacts for a later time (the user confirms it).', {
          'name': _s('Contact name as the user said it'),
          'text': _s('The message'),
          'time': _s('Local date-time in ISO 8601 without timezone'),
          'via': {'type': 'string', 'enum': ['whatsapp', 'sms', 'default']},
        }, ['name', 'text', 'time']),
        _fn('list_reminders', 'Show upcoming reminders and scheduled messages.', {}, []),
        _fn('cancel_reminder', 'Cancel a reminder or scheduled message.',
            {'about': _s('Words that identify it')}, ['about']),
        _fn('generate_image', 'Draw / create a picture from a description.',
            {'prompt': _s('A detailed description of the picture, in English')}, ['prompt']),
        _fn('remember',
            'Save a lasting fact about the user or people in their life, when they ask you to remember '
                'something or clearly tell you such a fact (e.g. "my brother is Ravi", "I\'m vegetarian").',
            {'fact': _s('The fact, written short and in third person-free form, e.g. "Brother is Ravi"')},
            ['fact']),
        _fn('forget', 'Delete a remembered fact when the user asks you to forget it.',
            {'about': _s('Words that identify the fact')}, ['about']),
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
        'When the user sends a picture, look at it carefully and answer about it directly. '
        'Current local time: ${now.toIso8601String()} (${_weekday(now.weekday)}). '
        'User\'s name: ${prefs.name}. '
        'Installed apps: ${names.join(', ')}.'
        '${_music(notifs)}'
        '${memory.facts.isEmpty ? '' : '\n\nThings the user asked you to remember:\n${memory.facts.map((f) => '- $f').join('\n')}'}'
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
    // Error lines aren't real answers, and on-phone answers may hold private details: leave both out
    final talk = msgs.where((m) => !m.isNotif && !m.error && !m.local && m.text.trim().isNotEmpty).toList();
    for (final m in talk.length > 16 ? talk.sublist(talk.length - 16) : talk) {
      final role = m.me ? 'user' : 'model';
      final text = m.quote == null
          ? m.text
          : Privacy.text(m.quote)
              ? '(replying to ${m.quoteName ?? 'a message'}, a private message I won\'t share) ${m.text}'
              : '(replying to ${m.quoteName ?? 'a message'}: "${m.quote}") ${m.text}';
      if (out.isNotEmpty && out.last['role'] == role) {
        if (role == 'user') {
          // An earlier message that never got an answer: drop it so Gemini answers the newest one
          out[out.length - 1] = {'role': 'user', 'parts': <Map>[{'text': text}]};
        } else {
          (out.last['parts'] as List).add({'text': text});
        }
      } else {
        out.add({'role': role, 'parts': <Map>[{'text': text}]});
      }
    }
    while (out.isNotEmpty && out.first['role'] != 'user') {
      out.removeAt(0);
    }
    return out;
  }

  /// Main call: Gemini decides to reply and/or call functions.
  static Future<GeminiResult> ask(List<Msg> history, List<AppEntry> apps, List<Msg> notifs,
      {String? imagePath}) async {
    final contents = _history(history);
    // Attach the picture to your newest message so Gemini can see it
    if (imagePath != null && contents.isNotEmpty && contents.last['role'] == 'user') {
      try {
        final bytes = await File(imagePath).readAsBytes();
        (contents.last['parts'] as List)
            .insert(0, {'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(bytes)}});
      } catch (_) {}
    }
    final body = {
      'systemInstruction': {'parts': [{'text': _system(apps, notifs)}]},
      'contents': contents,
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
    final r = await _post(body);
    if (r.via == 'openrouter' && r.error == null) {
      return GeminiResult(text: '${r.text}\n\n_(Gemini is busy, so this is from the backup AI without live search.)_', via: r.via);
    }
    return r;
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
    if (prefs.geminiKey.trim().isEmpty) return _router(body);
    final r = await _postGemini(body);
    if (r.error != null && prefs.routerKey.trim().isNotEmpty && !r.error!.contains('offline')) {
      final b = await _router(body);
      if (b.error == null) return b;
    }
    return r;
  }

  static Future<GeminiResult> _postGemini(Map body) async {
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

  // ---------- OpenRouter: one key, many free models, used when Gemini is busy ----------
  static Future<List<String>> _routerModels() async {
    if (prefs.routerModels.isNotEmpty &&
        DateTime.now().millisecondsSinceEpoch - prefs.routerModelsAt < 24 * 3600 * 1000) {
      return prefs.routerModels;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse('https://openrouter.ai/api/v1/models'));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final raw = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return prefs.routerModels;
      final all = (jsonDecode(raw)['data'] as List? ?? []).whereType<Map>().where((m) {
        final p = m['pricing'] as Map? ?? {};
        final free = '${m['id']}'.endsWith(':free') || (p['prompt'] == '0' && p['completion'] == '0');
        final params = (m['supported_parameters'] as List? ?? []).map((e) => '$e');
        return free && params.contains('tools');
      }).toList()
        ..sort((a, b) => ((b['context_length'] as num?) ?? 0).compareTo((a['context_length'] as num?) ?? 0));
      final ids = all.take(5).map((m) => '${m['id']}').toList();
      if (ids.isNotEmpty) prefs.setRouterModels(ids);
      return ids.isNotEmpty ? ids : prefs.routerModels;
    } catch (_) {
      return prefs.routerModels;
    } finally {
      client.close();
    }
  }

  /// Sends the same request to OpenRouter in its (OpenAI-style) format.
  static Future<GeminiResult> _router(Map body) async {
    if (prefs.routerKey.trim().isEmpty) {
      return GeminiResult(error: 'Add a Gemini or OpenRouter key in Vibe settings.');
    }
    final models = await _routerModels();
    if (models.isEmpty) return GeminiResult(error: 'Couldn\'t reach OpenRouter right now.', via: 'openrouter');

    final msgs = <Map>[];
    final sys = (body['systemInstruction'] as Map?)?['parts']?[0]?['text'];
    if (sys is String) msgs.add({'role': 'system', 'content': sys});
    for (final c in (body['contents'] as List? ?? [])) {
      if (c is! Map) continue;
      final text = (c['parts'] as List? ?? [])
          .whereType<Map>()
          .where((p) => p['text'] is String)
          .map((p) => p['text'] as String)
          .join('\n');
      if (text.isNotEmpty) msgs.add({'role': c['role'] == 'model' ? 'assistant' : 'user', 'content': text});
    }
    final tools = <Map>[];
    for (final t in (body['tools'] as List? ?? [])) {
      if (t is Map && t['functionDeclarations'] is List) {
        for (final f in t['functionDeclarations'] as List) {
          tools.add({'type': 'function', 'function': f});
        }
      }
    }
    final req = {
      'model': models.first,
      'models': models.take(3).toList(),
      'messages': msgs,
      if (tools.isNotEmpty) 'tools': tools,
    };

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final r = await client.postUrl(Uri.parse('https://openrouter.ai/api/v1/chat/completions'));
      r.headers.contentType = ContentType.json;
      r.headers.set('Authorization', 'Bearer ${prefs.routerKey.trim()}');
      r.headers.set('X-Title', 'Vibe Launcher');
      r.add(utf8.encode(jsonEncode(req)));
      final res = await r.close().timeout(const Duration(seconds: 60));
      final raw = await res.transform(utf8.decoder).join();
      Map j = {};
      try {
        j = jsonDecode(raw) as Map;
      } catch (_) {}
      if (res.statusCode == 401 || res.statusCode == 403) {
        return GeminiResult(error: 'Your OpenRouter key isn\'t working. Check it in Vibe settings.', via: 'openrouter');
      }
      if (res.statusCode != 200 || j['choices'] is! List || (j['choices'] as List).isEmpty) {
        return GeminiResult(error: 'The backup AI is busy too. Try again in a moment.', via: 'openrouter');
      }
      final m = ((j['choices'] as List).first as Map)['message'] as Map? ?? {};
      final calls = <Call>[];
      for (final tc in (m['tool_calls'] as List? ?? [])) {
        final f = (tc is Map ? tc['function'] : null) as Map?;
        if (f == null) continue;
        Map<String, dynamic> args = {};
        try {
          args = Map<String, dynamic>.from(jsonDecode('${f['arguments'] ?? '{}'}') as Map);
        } catch (_) {}
        calls.add((name: '${f['name']}', args: args));
      }
      return GeminiResult(text: '${m['content'] ?? ''}'.trim(), calls: calls, via: 'openrouter');
    } on SocketException {
      return GeminiResult(error: 'I\'m offline right now. I can still open your apps.', via: 'openrouter');
    } catch (_) {
      return GeminiResult(error: 'The backup AI didn\'t answer. Try again in a moment.', via: 'openrouter');
    } finally {
      client.close();
    }
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
