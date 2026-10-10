import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'chat.dart';
import 'launcher.dart';
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// Vibe's dial pad: type digits, T9 contact matches, recent calls. Calls go out through the phone app.
class DialerPage extends StatefulWidget {
  final String initial;
  const DialerPage({super.key, this.initial = ''});
  @override
  State<DialerPage> createState() => _DialerPageState();
}

class _DialerPageState extends State<DialerPage> {
  late String _num = widget.initial;
  List<Map> _recent = [];

  static const _keys = [
    ('1', ''), ('2', 'ABC'), ('3', 'DEF'),
    ('4', 'GHI'), ('5', 'JKL'), ('6', 'MNO'),
    ('7', 'PQRS'), ('8', 'TUV'), ('9', 'WXYZ'),
    ('*', ''), ('0', '+'), ('#', ''),
  ];
  static const _t9 = {
    'a': '2', 'b': '2', 'c': '2', 'd': '3', 'e': '3', 'f': '3', 'g': '4', 'h': '4', 'i': '4',
    'j': '5', 'k': '5', 'l': '5', 'm': '6', 'n': '6', 'o': '6', 'p': '7', 'q': '7', 'r': '7', 's': '7',
    't': '8', 'u': '8', 'v': '8', 'w': '9', 'x': '9', 'y': '9', 'z': '9',
  };

  @override
  void initState() {
    super.initState();
    People.ensure().then((_) async {
      final r = await Native.callLog(40);
      if (mounted) setState(() => _recent = r);
    });
  }

  String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');
  String _t9of(String name) => name.toLowerCase().split('').map((ch) => _t9[ch] ?? (RegExp(r'\d').hasMatch(ch) ? ch : ' ')).join();

  /// Contacts whose number contains the digits, or whose name's T9 keys start a word with them.
  List<Person> _matches() {
    final d = _digits(_num);
    if (d.isEmpty) return const [];
    final out = <(Person, int)>[];
    for (final p in People.all) {
      final pd = _digits(p.number);
      final words = _t9of(p.name).split(' ').where((w) => w.isNotEmpty);
      var score = 0;
      if (pd.endsWith(d) || pd.startsWith(d)) {
        score = 3;
      } else if (pd.contains(d)) {
        score = 2;
      } else if (d.length >= 2 && (words.any((w) => w.startsWith(d)) || _t9of(p.name).replaceAll(' ', '').startsWith(d))) {
        score = 1;
      }
      if (score > 0) out.add((p, score));
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return out.take(20).map((e) => e.$1).toList();
  }

  void _press(String k) {
    prefs.tap();
    setState(() => _num += k);
  }

  void _back() {
    if (_num.isEmpty) return;
    prefs.tap();
    setState(() => _num = _num.substring(0, _num.length - 1));
  }

  Future<void> _call(String number) async {
    final n = number.trim();
    if (n.isEmpty) {
      // Empty: redial the last number, like most phones
      if (_recent.isNotEmpty) setState(() => _num = '${_recent.first['number']}');
      return;
    }
    prefs.heavy();
    // Phone codes like *#06# only work inside the phone's own dialer
    final ok = n.startsWith('*#') ? await Native.dialPad(n) : await Native.call(n);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your phone didn\'t let me start the call.')));
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _message(String number) async {
    prefs.tap();
    if (prefs.messenger == 'whatsapp' && await Native.whatsapp(number, '')) return;
    await Native.smsApp(number, '');
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final typing = _num.isNotEmpty;
    final matches = _matches();
    final known = typing
        ? People.all.where((p) {
            final a = _digits(p.number), b = _digits(_num);
            return b.length >= 7 && a.length >= 7 && a.substring(a.length - 7) == b.substring(b.length - 7);
          }).firstOrNull
        : null;

    return Scaffold(
      backgroundColor: c.chat,
      body: SafeArea(
        child: Column(children: [
          // Top bar
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
            child: Row(children: [
              IconButton(icon: Icon(Icons.arrow_back_rounded, color: c.text), onPressed: () => Navigator.pop(context)),
              Text(typing ? 'Contacts' : 'Recent calls', style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w800)),
            ]),
          ),
          // Matches or recents
          Expanded(
            child: typing
                ? (matches.isEmpty
                    ? Center(child: Text('No contact matches', style: TextStyle(color: c.faint)))
                    : ListView(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        children: [
                          for (var i = 0; i < matches.length; i++)
                            Stagger(index: i, dy: 10, child: _personRow(c, matches[i])),
                        ],
                      ))
                : (_recent.isEmpty
                    ? Center(
                        child: Text(People.perms['calls'] == true ? 'No recent calls' : 'Allow call log in Vibe settings → People',
                            style: TextStyle(color: c.faint)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: _recent.length,
                        itemBuilder: (_, i) => Stagger(index: i, dy: 10, child: _recentRow(c, _recent[i])),
                      )),
          ),
          Divider(height: 1, color: c.divider),
          // Number display
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: !typing
                ? const SizedBox(width: double.infinity, height: 8)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: SelectableText(_num,
                                style: TextStyle(color: c.text, fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 1)),
                          ),
                          if (known != null)
                            Text(known.name, style: TextStyle(color: VC.blurple, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                      GestureDetector(
                        onLongPress: () {
                          prefs.heavy();
                          setState(() => _num = '');
                        },
                        child: IconButton(icon: Icon(Icons.backspace_outlined, color: c.muted), onPressed: _back),
                      ),
                    ]),
                  ),
          ),
          // Keypad
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              childAspectRatio: 1.75,
              mainAxisSpacing: 6,
              crossAxisSpacing: 14,
              children: [for (final k in _keys) _key(c, k.$1, k.$2)],
            ),
          ),
          // Actions
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 4, 32, 14),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              _small(c, Icons.chat_bubble_outline_rounded, 'Message', typing ? () => _message(_num) : null),
              Pressable(
                child: Material(
                  color: VC.green,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _call(_num),
                    child: const SizedBox(width: 68, height: 68, child: Icon(Icons.call_rounded, color: Colors.white, size: 30)),
                  ),
                ),
              ),
              _small(c, Icons.person_add_alt_1_rounded, 'Save',
                  typing && known == null ? () => Native.addContact(_num) : null),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _key(VC c, String d, String letters) => Material(
        color: c.pane,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _press(d),
          onLongPress: d == '0'
              ? () => _press('+')
              : d == '1'
                  ? () => _press(',')
                  : null,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(d, style: TextStyle(color: c.text, fontSize: 26, fontWeight: FontWeight.w500, height: 1.1)),
            if (letters.isNotEmpty)
              Text(letters, style: TextStyle(color: c.faint, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
          ]),
        ),
      );

  Widget _small(VC c, IconData icon, String label, VoidCallback? onTap) => SizedBox(
        width: 64,
        child: Opacity(
          opacity: onTap == null ? 0.35 : 1,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: c.muted),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(color: c.faint, fontSize: 11)),
            ]),
          ),
        ),
      );

  Widget _personRow(VC c, Person p) => ListTile(
        leading: PersonAvatar(name: p.name, person: p, size: 40),
        title: Text(p.name, style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
        subtitle: Text(p.number, style: TextStyle(color: c.faint)),
        onTap: () => _call(p.number),
        trailing: IconButton(icon: Icon(Icons.chat_bubble_outline_rounded, color: c.muted), onPressed: () => _message(p.number)),
      );

  Widget _recentRow(VC c, Map r) {
    final name = '${r['name'] ?? ''}'.isEmpty ? '${r['number']}' : '${r['name']}';
    final type = '${r['type']}';
    final t = DateTime.fromMillisecondsSinceEpoch(((r['time'] as num?) ?? 0).toInt());
    final icon = switch (type) {
      'missed' => Icons.call_missed_rounded,
      'outgoing' => Icons.call_made_rounded,
      'rejected' || 'blocked' => Icons.call_end_rounded,
      _ => Icons.call_received_rounded,
    };
    final bad = type == 'missed' || type == 'rejected';
    final secs = ((r['duration'] as num?) ?? 0).toInt();
    final dur = secs == 0 ? '' : ' · ${secs >= 60 ? '${secs ~/ 60}m ' : ''}${secs % 60}s';
    final p = People.all.where((x) {
      final a = _digits(x.number), b = _digits('${r['number']}');
      return a.length >= 7 && b.length >= 7 && a.substring(a.length - 7) == b.substring(b.length - 7);
    }).firstOrNull;
    return ListTile(
      leading: PersonAvatar(name: name, person: p, size: 40),
      title: Text(name,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: bad ? VC.red : c.text, fontWeight: FontWeight.w600)),
      subtitle: Row(children: [
        Icon(icon, size: 14, color: bad ? VC.red : c.faint),
        const SizedBox(width: 4),
        Text('${sameDay(t, DateTime.now()) ? clock(t) : '${dayLabel(t)}, ${clock(t)}'}$dur',
            style: TextStyle(color: c.faint, fontSize: 12)),
      ]),
      onTap: () => _call('${r['number']}'),
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: '${r['number']}'));
        setState(() => _num = '${r['number']}');
      },
      trailing: IconButton(
          icon: Icon(Icons.chat_bubble_outline_rounded, color: c.muted), onPressed: () => _message('${r['number']}')),
    );
  }
}
