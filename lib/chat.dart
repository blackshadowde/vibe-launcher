import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'launcher.dart';

/// One line in the Vibe chat: from you, from Vibe, or an app notification.
class Msg {
  final bool me;
  final String text;
  final int ts;
  final List<String> apps; // app cards shown under a Vibe reply
  final List<Map> links; // web sources: {t: title, u: url}
  final bool error;
  // Notifications
  final String? pkg; // set = this line is a notification from that app
  final String? app; // app name
  final String? title; // e.g. sender name
  final String? nkey; // Android notification key, for reply/open
  final bool canReply;
  // Your reply to a notification ("Ravi · WhatsApp"), or the previous song for a song change
  final String? quote; // preview text of the message being replied to
  final String? quoteName; // who wrote it (app, sender, "Vibe" or your name)
  final String? quotePkg; // its avatar: an app package, 'vibe' or 'me'
  final bool media; // music update from a player app
  /// Rich card under a Vibe reply: {type: contact|sms|calls, ...}
  final Map? card;
  final String? img; // picture you sent (path on the phone)
  final bool local; // answered by the on-phone AI (never sent to the cloud)

  Msg(this.me, this.text,
      {int? ts,
      this.apps = const [],
      this.links = const [],
      this.error = false,
      this.pkg,
      this.app,
      this.title,
      this.nkey,
      this.canReply = false,
      this.quote,
      this.quoteName,
      this.quotePkg,
      this.media = false,
      this.card,
      this.img,
      this.local = false})
      : ts = ts ?? DateTime.now().millisecondsSinceEpoch;

  bool get isNotif => pkg != null;
  String get sender => me ? 'me' : (pkg ?? 'vibe');

  Map toJson() => {
        'm': me,
        't': text,
        's': ts,
        if (apps.isNotEmpty) 'a': apps,
        if (links.isNotEmpty) 'l': links,
        if (error) 'e': true,
        if (pkg != null) 'p': pkg,
        if (app != null) 'n': app,
        if (title != null) 'h': title,
        if (nkey != null) 'k': nkey,
        if (canReply) 'r': true,
        if (quote != null) 'q': quote,
        if (quoteName != null) 'qn': quoteName,
        if (quotePkg != null) 'qp': quotePkg,
        if (media) 'md': true,
        if (card != null) 'x': card,
        if (img != null) 'i': img,
        if (local) 'lo': true,
      };
  static Msg fromJson(Map j) => Msg(j['m'] == true, j['t'] ?? '',
      ts: j['s'] ?? 0,
      apps: List<String>.from(j['a'] ?? const []),
      links: List<Map>.from(j['l'] ?? const []),
      error: j['e'] == true,
      pkg: j['p'],
      app: j['n'],
      title: j['h'],
      nkey: j['k'],
      canReply: j['r'] == true,
      quote: j['q'],
      quoteName: j['qn'],
      quotePkg: j['qp'],
      media: j['md'] == true,
      card: j['x'] is Map ? Map.from(j['x']) : null,
      img: j['i'],
      local: j['lo'] == true);
}

/// Chat history, kept on the phone (last 500 lines).
class ChatStore extends ChangeNotifier {
  List<Msg> msgs = [];

  void load() {
    try {
      final raw = prefs.sp.getString('chat');
      if (raw != null) msgs = (jsonDecode(raw) as List).map((e) => Msg.fromJson(e)).toList();
    } catch (_) {}
  }

  void add(Msg m) {
    msgs.add(m);
    if (msgs.length > 500) msgs = msgs.sublist(msgs.length - 500);
    prefs.sp.setString('chat', jsonEncode(msgs.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  /// Swap one line for an updated copy (e.g. an SMS card after sending).
  void replace(Msg old, Msg m) {
    final i = msgs.lastIndexOf(old);
    if (i < 0) return;
    msgs[i] = m;
    prefs.sp.setString('chat', jsonEncode(msgs.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  /// Swap the newest line (used to collapse quick play/pause toggles into one message).
  void replaceLast(Msg m) {
    if (msgs.isEmpty) return add(m);
    msgs[msgs.length - 1] = m;
    prefs.sp.setString('chat', jsonEncode(msgs.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  void clear() {
    msgs = [];
    prefs.sp.remove('chat');
    notifyListeners();
  }
}

final chat = ChatStore();

/// What Vibe decided to do with a message.
enum Act { none, open, drawer, phoneSettings, launcherSettings, clear, media }

class Reply {
  final String text;
  final Act act;
  final AppEntry? app;
  final List<AppEntry> choices;
  /// false = the offline brain didn't really understand; let Gemini try.
  final bool sure;
  final String media; // play / pause / next / previous
  Reply(this.text,
      {this.act = Act.none, this.app, this.choices = const [], this.sure = true, this.media = ''});
}

/// Offline command understanding. Gemini comes later for anything this can't handle.
class Brain {
  static const help = 'Here\'s what I can do right now:\n'
      '• "open calendar", or just "calendar"\n'
      '• "all apps", or swipe in from the left edge\n'
      '• "settings" for phone settings\n'
      '• "launcher settings"\n'
      '• "clear chat"\n'
      '• "pause", "play", "next", "previous" for music\n'
      '• "call mom", "message Ravi I\'ll be late", "whatsapp Priya hi", "who called me?"\n'
      '• "remember my brother is Ravi", "what do you remember", "forget …"\n'
      '• "remind me at 6pm to call mom", "remind me in 20 minutes", "message Ravi happy birthday at 12 tonight", "my reminders"\n'
      '• "good morning" or "my day" for your daily brief, "weather", "my city is Mumbai"\n'
      '• "what\'s on today?", "add dentist on friday at 5"\n'
      '• "offline mode on" to use no internet; questions get answered when you\'re back online\n'
      '• Tap + for Camera or Photos and ask about a picture, or share anything to Vibe from any app\n'
      '• Long-press my avatar for your recent apps\n'
      'Notifications show up here: tap Reply to answer, long-press to mute an app.\n'
      'With a Gemini key (launcher settings) you can also just talk to me: ask questions, '
      'search Google, play music, set alarms and timers, "what did I miss?", '
      '"reply to Ravi I\'m on my way".';

  static String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9ऀ-ॿ ]"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static final _openVerb = RegExp(r'^(please )?(open|launch|start|run|go to|goto|show me|show)\s+(the |my )?');
  static final _trailing = RegExp(r'\s+(app|application|please|now|for me)$');

  static Reply handle(String input, List<AppEntry> apps) {
    final q = norm(input);
    if (q.isEmpty) return Reply('🤔');

    if (const {'hi', 'hello', 'hey', 'hii', 'yo', 'hlo'}.contains(q)) {
      return Reply('Hey! What should I open?', sure: false);
    }
    if (const {'help', 'what can you do', 'commands', '?'}.contains(q)) return Reply(help);
    if (const {'clear', 'clear chat', 'delete chat', 'clear all'}.contains(q)) {
      return Reply('', act: Act.clear);
    }
    // Music controls, offline
    if (RegExp(r'^(pause|stop)( (the )?(music|song|it))?$').hasMatch(q)) {
      return Reply('Pausing…', act: Act.media, media: 'pause');
    }
    if (RegExp(r'^(resume|continue|play|unpause)( (the )?(music|song|it))?$').hasMatch(q)) {
      return Reply('Playing…', act: Act.media, media: 'play');
    }
    if (RegExp(r'^(next|skip)( (the )?(song|track|one))?$|^next song$|^play next$').hasMatch(q)) {
      return Reply('Next song…', act: Act.media, media: 'next');
    }
    if (RegExp(r'^(previous|prev|last|back)( (song|track|one))?$|^play previous$|^go back$').hasMatch(q)) {
      return Reply('Previous song…', act: Act.media, media: 'previous');
    }
    if (RegExp(r'^(open |show )?(all )?(apps|app list|applications|app drawer|drawer)$').hasMatch(q)) {
      return Reply('Here are all your apps.', act: Act.drawer);
    }
    if (RegExp(r'^(open |show )?(vibe |launcher )settings$').hasMatch(q)) {
      return Reply('Opening launcher settings…', act: Act.launcherSettings);
    }
    if (RegExp(r'^(open |show )?(phone |system |android )?settings$').hasMatch(q)) {
      return Reply('Opening Settings…', act: Act.phoneSettings);
    }

    final hasVerb = _openVerb.hasMatch(q);
    var name = q.replaceFirst(_openVerb, '');
    while (_trailing.hasMatch(name)) {
      name = name.replaceFirst(_trailing, '');
    }
    final found = match(name, apps);

    if (found.isEmpty) {
      return Reply(
          hasVerb
              ? 'I couldn\'t find an app called "$name". Swipe in from the left to see all apps.'
              : 'I don\'t understand that yet. Try "open WhatsApp", or type "help". '
                  'Add a Gemini key in launcher settings and I can chat, search and do much more.',
          sure: false);
    }
    final best = found.first;
    final strong = best.score >= 80 || (hasVerb && best.score >= 50);
    final tie = found.length > 1 && found[1].score == best.score;
    if (strong && !tie) {
      // score 60 = app name found inside a longer sentence ("open youtube and play lofi"):
      // fine offline, but Gemini understands the rest of the sentence better
      return Reply('Opening ${best.app.label}…', act: Act.open, app: best.app, sure: best.score > 60);
    }
    if (!hasVerb && best.score < 60) {
      return Reply('I don\'t understand that yet. Try "open WhatsApp", or type "help".', sure: false);
    }
    // A long sentence that only loosely matches an app is probably a question, not an app name
    if (!hasVerb && name.split(' ').length > 3) {
      return Reply('Did you mean one of these?',
          choices: found.take(4).map((e) => e.app).toList(), sure: false);
    }
    return Reply(found.length == 1 ? 'Did you mean this?' : 'Which one?',
        choices: found.take(4).map((e) => e.app).toList());
  }

  static List<({AppEntry app, int score})> match(String q, List<AppEntry> apps) {
    if (q.length < 2) return [];
    final out = <({AppEntry app, int score})>[];
    for (final a in apps) {
      final n = norm(a.label);
      if (n.isEmpty) continue;
      int s = 0;
      if (n == q) {
        s = 100;
      } else if (n.replaceAll(' ', '') == q.replaceAll(' ', '')) {
        s = 95;
      } else if (n.startsWith(q)) {
        s = 85;
      } else if (n.split(' ').any((w) => w.startsWith(q))) {
        s = 75;
      } else if (n.contains(q)) {
        s = 65;
      } else if (n.length >= 3 && q.split(' ').contains(n)) {
        s = 60;
      } else {
        final d = _lev(n, q);
        if (d <= max(1, q.length ~/ 4)) s = 55 - d;
      }
      if (s > 0) out.add((app: a, score: s));
    }
    out.sort((a, b) {
      final d = b.score.compareTo(a.score);
      if (d != 0) return d;
      return (prefs.lastUsed[b.app.pkg] ?? 0).compareTo(prefs.lastUsed[a.app.pkg] ?? 0);
    });
    // Break ties in favour of the app you use most recently
    if (out.length > 1 &&
        out[0].score == out[1].score &&
        (prefs.lastUsed[out[0].app.pkg] ?? 0) > (prefs.lastUsed[out[1].app.pkg] ?? 0)) {
      return [(app: out[0].app, score: out[0].score + 1), ...out.skip(1)];
    }
    return out;
  }

  static int _lev(String a, String b) {
    if ((a.length - b.length).abs() > 3) return 99;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1),
            prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
      }
      prev = cur;
    }
    return prev[b.length];
  }
}

String clock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String dayLabel(DateTime t) {
  final now = DateTime.now();
  if (sameDay(t, now)) return 'Today';
  if (sameDay(t, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  if (sameDay(t, now.add(const Duration(days: 1)))) return 'Tomorrow';
  return '${t.day}/${t.month}/${t.year}';
}

String stamp(DateTime t) {
  final d = dayLabel(t);
  return d == 'Today' || d == 'Yesterday' || d == 'Tomorrow' ? '$d at ${clock(t)}' : '$d ${clock(t)}';
}
