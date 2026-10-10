import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'chat.dart';
import 'launcher.dart';
import 'memory.dart';
import 'theme.dart';

/// One phone number of a contact.
class Person {
  final String id, name, number;
  final bool mobile, primary, starred, hasPhoto;
  Person(this.id, this.name, this.number, this.mobile, this.primary, this.starred, this.hasPhoto);
}

/// What a people command asked for.
class PeopleCmd {
  final String action; // call / message / calls
  final String name, text, via; // via: whatsapp / sms / '' (default)
  PeopleCmd(this.action, {this.name = '', this.text = '', this.via = ''});
}

/// Contacts on the phone, matched by name like apps are.
class People {
  static List<Person> all = []; // one entry per contact (best number)
  static Map<String, bool> perms = {};
  static bool get ready => perms['contacts'] == true;
  static final Map<String, Future<Uint8List?>> _photos = {};

  static Future<void> load() async {
    perms = Map<String, bool>.from(await Native.peoplePerms());
    if (!ready) return;
    final raw = await Native.contacts();
    final byId = <String, Person>{};
    for (final m in raw) {
      final p = Person(m['id'].toString(), m['name'].toString(), m['number'].toString(), m['mobile'] == true,
          m['primary'] == true, m['starred'] == true, m['photo'] == true);
      final old = byId[p.id];
      // Keep the number they'd most likely want: default, then mobile
      if (old == null || (p.primary && !old.primary) || (p.mobile && !old.mobile && !old.primary)) byId[p.id] = p;
    }
    all = byId.values.toList();
  }

  /// Asks for contacts/calls/SMS permission if missing. True when contacts are readable.
  static Future<bool> ensure() async {
    perms = Map<String, bool>.from(await Native.peoplePerms());
    if (perms.values.every((v) => v)) {
      if (all.isEmpty) await load();
      return ready;
    }
    perms = Map<String, bool>.from(await Native.requestPeople());
    await load();
    return ready;
  }

  static Future<Uint8List?> photo(Person p) =>
      _photos.putIfAbsent(p.id, () => p.hasPhoto ? Native.contactPhoto(p.id) : Future.value(null));

  static const _aliases = {
    'mom': ['mom', 'mum', 'mummy', 'mommy', 'amma', 'maa', 'ma', 'mother', 'ammi', 'aai'],
    'dad': ['dad', 'daddy', 'papa', 'pappa', 'nanna', 'appa', 'abba', 'father', 'baba', 'pitaji'],
    'wife': ['wife', 'wifey', 'biwi'],
    'husband': ['husband', 'hubby'],
    'brother': ['bro', 'brother', 'bhai', 'anna'],
    'sister': ['sis', 'sister', 'didi', 'akka'],
  };

  static List<({Person p, int score})> match(String query) {
    final q = Brain.norm(query).replaceFirst(RegExp(r'^(my|the) '), '');
    if (q.isEmpty) return [];
    final words = {q};
    for (final group in _aliases.values) {
      if (group.contains(q)) words.addAll(group);
    }
    final out = <({Person p, int score})>[];
    for (final p in all) {
      final n = Brain.norm(p.name);
      if (n.isEmpty) continue;
      var best = 0;
      for (final w in words) {
        int s = 0;
        if (n == w) {
          s = 100;
        } else if (n.startsWith('$w ')) {
          s = 88; // first name
        } else if (n.split(' ').contains(w)) {
          s = 80;
        } else if (n.startsWith(w) && w.length >= 3) {
          s = 70;
        } else if (n.contains(w) && w.length >= 4) {
          s = 60;
        }
        if (w != q) s = s > 0 ? s - 2 : 0; // alias match ranks just below the exact word
        if (s > best) best = s;
      }
      // Memory: "my brother is Ravi" makes "call my brother" find Ravi
      if (best < 90) {
        final first = n.split(' ').first;
        for (final f in memory.namesFor(q)) {
          final fw = f.split(' ');
          if (first.length >= 3 && fw.contains(first)) best = 92;
        }
      }
      if (best == 0 && q.length >= 4) {
        final first = n.split(' ').first;
        final d = _lev(first, q);
        if (d <= 1) best = 50;
      }
      if (best > 0) out.add((p: p, score: best + (p.starred ? 1 : 0)));
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  /// Contact for a notification title like "Ravi" or "Ravi · Family group".
  static Person? fromTitle(String? title) {
    if (title == null || title.isEmpty || all.isEmpty) return null;
    final who = Brain.norm(title.split(' · ').first);
    if (who.length < 2) return null;
    for (final p in all) {
      if (Brain.norm(p.name) == who) return p;
    }
    return null;
  }

  /// Understands "call mom", "message ravi i'll be late", "whatsapp priya hi", "who called me".
  static PeopleCmd? parse(String input) {
    final t = input.trim();
    final low = Brain.norm(t);
    if (RegExp(r'^(who called( me)?|any (missed )?calls|missed calls?|recent calls|call (log|history)|my calls)$')
        .hasMatch(low)) {
      return PeopleCmd('calls');
    }
    final call = RegExp(r'^(?:please\s+)?(?:call|ring|phone|dial)\s+(.+?)(?:\s+(?:now|please))?[.!]?$',
            caseSensitive: false)
        .firstMatch(t);
    if (call != null) return PeopleCmd('call', name: call.group(1)!);

    final msg = RegExp(
            r'^(?:please\s+)?(message|msg|text|sms|whatsapp|send\s+(?:a\s+)?(?:message|msg|text)\s+to)\s+(.+)$',
            caseSensitive: false)
        .firstMatch(t);
    if (msg == null) return null;
    final verb = msg.group(1)!.toLowerCase();
    var rest = msg.group(2)!.trim();
    var via = verb == 'whatsapp' ? 'whatsapp' : (verb == 'sms' || verb == 'text') ? 'sms' : '';
    final on = RegExp(r'\s+(?:on|via|by|in)\s+(whatsapp|sms|text)\b', caseSensitive: false).firstMatch(rest);
    if (on != null) {
      via = on.group(1)!.toLowerCase() == 'whatsapp' ? 'whatsapp' : 'sms';
      rest = (rest.substring(0, on.start) + rest.substring(on.end)).trim();
    }
    // A phone number first: "message +91 98765 43210 I'm late"
    final numM = RegExp(r'^(\+?\d[\d\s\-()]{4,}\d)(?:\s+(.*))?$').firstMatch(rest);
    if (numM != null) {
      final text = (numM.group(2) ?? '').replaceFirst(RegExp(r'^(that|saying|to say|:|-)\s*', caseSensitive: false), '').trim();
      return PeopleCmd('message', name: numM.group(1)!.trim(), text: text, via: via);
    }
    // Longest run of first words that is a contact = the name; the rest is the message
    final words = rest.split(RegExp(r'\s+'));
    for (var k = words.length > 4 ? 4 : words.length; k >= 1; k--) {
      final name = words.take(k).join(' ');
      final m = match(name);
      if (m.isNotEmpty && m.first.score >= 60) {
        var text = words.skip(k).join(' ');
        text = text.replaceFirst(RegExp(r'^(that|saying|to say|:|-)\s*', caseSensitive: false), '').trim();
        return PeopleCmd('message', name: name, text: text, via: via);
      }
    }
    return PeopleCmd('message', name: words.first, text: words.skip(1).join(' '), via: via);
  }

  static int _lev(String a, String b) {
    if ((a.length - b.length).abs() > 2) return 9;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final c = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
        cur[j] = [cur[j - 1] + 1, prev[j] + 1, c].reduce((x, y) => x < y ? x : y);
      }
      prev = cur;
    }
    return prev[b.length];
  }
}

/// Round contact photo, or coloured initial, with an optional app badge.
class PersonAvatar extends StatelessWidget {
  final String name;
  final Person? person;
  final double size;
  final Widget? badge;
  const PersonAvatar({super.key, required this.name, this.person, this.size = 40, this.badge});

  static const _colors = [
    Color(0xFF5865F2), Color(0xFF3BA55C), Color(0xFFFAA61A), Color(0xFFED4245),
    Color(0xFFEB459E), Color(0xFF00A8FC), Color(0xFF9B59B6), Color(0xFF1ABC9C),
  ];

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final initial = CircleAvatar(
      radius: size / 2,
      backgroundColor: _colors[name.hashCode.abs() % _colors.length],
      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: TextStyle(color: Colors.white, fontSize: size * 0.42, fontWeight: FontWeight.w700)),
    );
    final p = person;
    final face = p == null
        ? initial
        : FutureBuilder<Uint8List?>(
            future: People.photo(p),
            builder: (_, snap) => snap.data == null
                ? initial
                : ClipOval(
                    child: Image.memory(snap.data!, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true)),
          );
    if (badge == null) return SizedBox(width: size, height: size, child: face);
    final b = size * 0.42;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        face,
        Positioned(
          right: -3,
          bottom: -3,
          child: Container(
            width: b + 4,
            height: b + 4,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: c.chat, shape: BoxShape.circle),
            child: ClipOval(child: SizedBox(width: b, height: b, child: badge)),
          ),
        ),
      ]),
    );
  }
}
