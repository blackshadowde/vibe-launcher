import 'package:flutter/foundation.dart';
import 'chat.dart';
import 'launcher.dart';

/// Things you asked Vibe to remember. Kept only on this phone (and shared with Gemini when you chat).
class Memory extends ChangeNotifier {
  List<String> facts = [];

  void load() => facts = prefs.sp.getStringList('memory') ?? [];
  void _save() {
    prefs.sp.setStringList('memory', facts);
    notifyListeners();
  }

  /// Adds a fact (skips near-duplicates). Returns the cleaned-up fact.
  String add(String fact) {
    var f = fact.trim().replaceAll(RegExp(r'\s+'), ' ');
    f = f.replaceFirst(RegExp(r'[.!]+$'), '');
    if (f.isEmpty) return f;
    f = f[0].toUpperCase() + f.substring(1);
    final n = Brain.norm(f);
    facts.removeWhere((e) => Brain.norm(e) == n);
    facts.add(f);
    if (facts.length > 200) facts.removeAt(0);
    _save();
    return f;
  }

  /// Removes the fact that best matches the words given. Returns it, or null if nothing matched.
  String? forget(String about) {
    final words = Brain.norm(about).split(' ').where((w) => w.length > 2).toSet();
    if (words.isEmpty || facts.isEmpty) return null;
    var best = -1, bestScore = 0;
    for (var i = 0; i < facts.length; i++) {
      final f = Brain.norm(facts[i]).split(' ').toSet();
      final score = words.where(f.contains).length;
      if (score > bestScore) {
        best = i;
        bestScore = score;
      }
    }
    if (best < 0) return null;
    final gone = facts.removeAt(best);
    _save();
    return gone;
  }

  void removeAt(int i) {
    facts.removeAt(i);
    _save();
  }

  void clear() {
    facts = [];
    _save();
  }

  /// Offline commands: "remember …", "what do you remember", "forget …". Null = not a memory command.
  String? handle(String input) {
    final t = input.trim();
    final low = Brain.norm(t);
    if (RegExp(r'^(what do you (remember|know)( about me)?|what have you remembered|my memories|show (my )?memor(y|ies))$')
        .hasMatch(low)) {
      if (facts.isEmpty) return 'I haven\'t been asked to remember anything yet. Try "remember my brother is Ravi".';
      return 'Here\'s what I remember:\n${facts.map((f) => '• $f').join('\n')}';
    }
    if (RegExp(r'^forget (everything|all( of it)?|all memories)$').hasMatch(low)) {
      final n = facts.length;
      clear();
      return n == 0 ? 'There was nothing to forget.' : 'Done. I\'ve forgotten all $n things.';
    }
    final rem = RegExp(r"^(?:please\s+)?(?:remember|note down|note|don't forget|dont forget)(?:\s+that)?\s+(.+)$",
            caseSensitive: false)
        .firstMatch(t);
    if (rem != null) {
      final f = add(rem.group(1)!);
      return 'Got it. I\'ll remember: $f';
    }
    final fg = RegExp(r'^(?:please\s+)?forget(?:\s+that|\s+about)?\s+(.+)$', caseSensitive: false).firstMatch(t);
    if (fg != null) {
      final gone = forget(fg.group(1)!);
      return gone == null ? 'I couldn\'t find that in what I remember.' : 'Forgotten: $gone';
    }
    return null;
  }

  /// Contact names mentioned in facts that also mention [word], e.g. "brother" → "Ravi".
  List<String> namesFor(String word) {
    final w = Brain.norm(word);
    if (w.length < 2) return [];
    final out = <String>[];
    for (final f in facts) {
      final words = Brain.norm(f).split(' ');
      if (words.contains(w)) out.add(Brain.norm(f));
    }
    return out;
  }
}

final memory = Memory();
