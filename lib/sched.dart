import 'chat.dart';

/// Finds a time in a sentence ("at 6pm", "in 20 minutes", "tomorrow at 9", "12 tonight",
/// "on friday at 5") and returns it with the rest of the sentence.
class When {
  final DateTime at;
  final String rest;
  When(this.at, this.rest);

  static const _days = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
  static const _nums = {
    'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'ten': 10,
    'fifteen': 15, 'twenty': 20, 'thirty': 30, 'forty five': 45, 'half an': 30, 'half': 30,
  };

  static When? find(String input, {DateTime? now}) {
    final n = now ?? DateTime.now();
    var s = ' ${input.trim()} ';

    String cut(Match m) => (s.substring(0, m.start) + ' ' + s.substring(m.end)).replaceAll(RegExp(r'\s+'), ' ');

    // "in 20 minutes", "in an hour", "in 2 hours", "in half an hour"
    final rel = RegExp(
            r'\s(?:in|after)\s+(\d+|a|an|one|two|three|four|five|six|ten|fifteen|twenty|thirty|forty five|half an|half)\s*(min|mins|minute|minutes|hr|hrs|hour|hours|sec|secs|seconds?)\b',
            caseSensitive: false)
        .firstMatch(s);
    if (rel != null) {
      final q = rel.group(1)!.toLowerCase();
      final v = int.tryParse(q) ?? _nums[q] ?? 1;
      final unit = rel.group(2)!.toLowerCase();
      final d = unit.startsWith('h')
          ? Duration(minutes: q.startsWith('half') ? 30 : v * 60)
          : unit.startsWith('s')
              ? Duration(seconds: v)
              : Duration(minutes: v);
      return When(n.add(d), _tidy(cut(rel)));
    }

    // Day words
    var dayOffset = -1; // -1 = not said
    bool tonight = false, morning = false, evening = false;
    final dayRe = RegExp(
        r'\s(today|tonight|tomorrow|tmrw|tmr|day after tomorrow|this evening|this morning|tomorrow morning|tomorrow evening|tomorrow night|(?:on\s+|next\s+|this\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b',
        caseSensitive: false);
    final dm = dayRe.firstMatch(s);
    if (dm != null) {
      final w = dm.group(1)!.toLowerCase();
      if (w.contains('day after')) {
        dayOffset = 2;
      } else if (w.startsWith('tom') || w.startsWith('tm')) {
        dayOffset = 1;
      } else if (w == 'today' || w.startsWith('this ') || w == 'tonight') {
        dayOffset = 0;
      }
      tonight = w == 'tonight' || w.endsWith('night');
      morning = w.endsWith('morning');
      evening = w.endsWith('evening');
      for (var i = 0; i < 7; i++) {
        if (w.endsWith(_days[i])) {
          var diff = (i + 1 - n.weekday) % 7;
          if (diff == 0 || w.startsWith('next')) diff = diff == 0 ? 7 : diff;
          dayOffset = diff;
        }
      }
      s = cut(dm);
    }

    // Clock time: "at 6", "at 6:30pm", "6 pm", "at noon", "midnight", "12 tonight"
    int? h, mi;
    final special = RegExp(r'\s(?:at\s+)?(noon|midday|midnight)\b', caseSensitive: false).firstMatch(s);
    if (special != null) {
      final w = special.group(1)!.toLowerCase();
      h = w == 'midnight' ? 24 : 12;
      mi = 0;
      s = cut(special);
    } else {
      final t = RegExp(r'\s(?:at\s+|@\s*|by\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?=\s)',
              caseSensitive: false)
          .allMatches(s)
          .where((m) {
        final full = m.group(0)!.toLowerCase();
        // Needs "at"/"@", am/pm, minutes, or a day word, so plain numbers in the message stay put
        return full.contains('at ') || full.contains('@') || full.contains('by ') || m.group(3) != null ||
            m.group(2) != null;
      }).toList();
      if (t.isNotEmpty) {
        final m = t.first;
        h = int.parse(m.group(1)!);
        mi = int.tryParse(m.group(2) ?? '') ?? 0;
        final ap = (m.group(3) ?? '').replaceAll('.', '').toLowerCase();
        if (h > 23 || mi > 59) return null;
        if (ap == 'pm' && h < 12) h += 12;
        if (ap == 'am' && h == 12) h = 0;
        if (ap.isEmpty && h <= 12) {
          if (tonight || evening) {
            if (h == 12) {
              h = 24;
            } else if (h < 12) {
              h += 12;
            }
          } else if (morning) {
            if (h == 12) h = 0;
          } else if (dayOffset > 0) {
            if (h >= 1 && h <= 7) h += 12; // "tomorrow at 5" = evening
          } else {
            // Today without am/pm: the next time it comes round
            final am = DateTime(n.year, n.month, n.day, h == 12 ? 12 : h, mi);
            final pm = DateTime(n.year, n.month, n.day, h == 12 ? 24 : h + 12, mi);
            if (am.isAfter(n)) {
              h = h == 12 ? 12 : h;
            } else if (pm.isAfter(n)) {
              h = h == 12 ? 24 : h + 12;
            } else {
              dayOffset = 1;
            }
          }
        }
        s = cut(m);
      }
    }

    if (h == null && dayOffset < 0) return null;
    h ??= tonight ? 21 : evening ? 18 : 9;
    mi ??= 0;
    var at = DateTime(n.year, n.month, n.day + (dayOffset < 0 ? 0 : dayOffset), h, mi);
    if (dayOffset < 0 && !at.isAfter(n)) at = at.add(const Duration(days: 1));
    if (!at.isAfter(n)) return null;
    return When(at, _tidy(s));
  }

  static String _tidy(String s) => s
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'^(to|that|about|for)\s+', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\s+(at|on|by|in)$', caseSensitive: false), '')
      .replaceFirst(RegExp(r'[,.]+$'), '')
      .trim();

  /// "Today at 6:00 PM", "Tomorrow at 9:00 AM", "in 20 min"
  static String label(DateTime t) {
    final d = t.difference(DateTime.now());
    if (d.inMinutes < 60 && d.inMinutes >= 1) return 'in ${d.inMinutes} min (${clock(t)})';
    if (d.inSeconds < 60) return 'in ${d.inSeconds} sec';
    return stamp(t);
  }
}

/// "remind me …" parsed into what + when.
class ReminderCmd {
  final String text;
  final DateTime? at;
  ReminderCmd(this.text, this.at);

  static ReminderCmd? parse(String input) {
    final m = RegExp(
            r'^(?:please\s+)?(?:remind me|set (?:a )?reminder|reminder|alert me|ping me)\s*(?:to|that|about|for)?\s*(.*)$',
            caseSensitive: false)
        .firstMatch(input.trim());
    if (m == null) return null;
    final rest = m.group(1)!.trim();
    final w = When.find(rest);
    if (w == null) return ReminderCmd(rest, null);
    return ReminderCmd(w.rest.isEmpty ? 'Reminder' : w.rest, w.at);
  }
}

bool isListCmd(String input) => RegExp(
        r'^(my reminders|show (my )?reminders|list (my )?reminders|what.?s scheduled|scheduled( messages)?|upcoming reminders|any reminders\??)$',
        caseSensitive: false)
    .hasMatch(input.trim());
