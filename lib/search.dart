import 'dart:async';
import 'package:flutter/material.dart';
import 'chat.dart';
import 'launcher.dart';
import 'mail.dart';
import 'memory.dart';
import 'people.dart';
import 'privacy.dart';
import 'theme.dart';
import 'widgets.dart';

/// One search box for everything: apps, contacts, chat, notifications, SMS, files,
/// calendar, reminders, memory and Gmail. Everything except Gmail is searched on the phone.
class SearchPage extends StatefulWidget {
  final List<AppEntry> apps;
  final String initial;
  final void Function(AppEntry) onLaunch;
  final void Function()? onMailSettings;
  const SearchPage({super.key, required this.apps, required this.onLaunch, this.initial = '', this.onMailSettings});

  static Future<void> open(BuildContext context,
      {required List<AppEntry> apps,
      required void Function(AppEntry) onLaunch,
      String initial = '',
      void Function()? onMailSettings}) {
    return Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) =>
          SearchPage(apps: apps, onLaunch: onLaunch, initial: initial, onMailSettings: onMailSettings),
      transitionsBuilder: (_, a, __, child) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.04), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    ));
  }

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _ctrl = TextEditingController(text: widget.initial);
  final _focus = FocusNode();
  Timer? _debounce;
  String _q = '';
  int _gen = 0;

  List<AppEntry> _apps = [];
  List<Person> _people = [];
  List<Msg> _chat = [];
  List<String> _mem = [];
  List<Map> _sms = [], _files = [], _events = [], _sched = [];
  List<MailHit>? _mail;
  String? _mailError;
  bool _mailBusy = false;
  Map _perms = {};
  final Set<String> _expanded = {};
  final Set<int> _revealed = {};

  @override
  void initState() {
    super.initState();
    Native.searchPerms().then((p) {
      if (mounted) setState(() => _perms = p);
    });
    if (People.all.isEmpty) People.load();
    if (widget.initial.isNotEmpty) _run(widget.initial);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () => _run(v));
  }

  Future<void> _run(String raw) async {
    final q = raw.trim();
    final gen = ++_gen;
    final n = Brain.norm(q);
    setState(() {
      _q = q;
      _mail = null;
      _mailError = null;
      _expanded.clear();
      if (q.length < 2) {
        _apps = [];
        _people = [];
        _chat = [];
        _mem = [];
        _sms = [];
        _files = [];
        _events = [];
        _sched = [];
        return;
      }
      // Instant, on-phone results
      _apps = Brain.match(n, widget.apps).map((e) => e.app).toList();
      _people = People.match(q).map((e) => e.p).toList();
      final low = q.toLowerCase();
      _chat = chat.msgs.reversed
          .where((m) => m.text.toLowerCase().contains(low) || (m.title ?? '').toLowerCase().contains(low))
          .take(40)
          .toList();
      _mem = memory.facts.where((f) => f.toLowerCase().contains(low)).toList();
    });
    if (q.length < 2) return;
    final r = await Future.wait([
      Native.searchSms(q),
      Native.searchFiles(q),
      Native.searchEvents(q),
      Native.listSched(),
    ]);
    if (!mounted || gen != _gen) return;
    final low = q.toLowerCase();
    setState(() {
      _sms = r[0];
      _files = r[1];
      _events = r[2];
      _sched = r[3]
          .where((e) => '${e['text']} ${e['name'] ?? ''}'.toLowerCase().contains(low) && e['type'] != 'brief')
          .toList();
    });
  }

  Future<void> _searchMail() async {
    if (_q.length < 2) return;
    setState(() {
      _mailBusy = true;
      _mailError = null;
    });
    try {
      final hits = await Mail.search(_q);
      if (mounted) setState(() => _mail = hits);
    } catch (e) {
      if (mounted) setState(() => _mailError = e.toString());
    } finally {
      if (mounted) setState(() => _mailBusy = false);
    }
  }

  int get _total =>
      _apps.length + _people.length + _chat.length + _mem.length + _sms.length + _files.length + _events.length + _sched.length;

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return Scaffold(
      backgroundColor: c.chat,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(children: [
              IconButton(
                icon: Icon(Icons.arrow_back_rounded, color: c.text),
                onPressed: () => Navigator.pop(context),
              ),
              Expanded(
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(color: c.input, borderRadius: BorderRadius.circular(22)),
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    onChanged: _changed,
                    onSubmitted: (v) {
                      _run(v);
                      if (Mail.ready) _searchMail();
                    },
                    textInputAction: TextInputAction.search,
                    style: TextStyle(color: c.text, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: 'Search apps, people, messages, files…',
                      hintStyle: TextStyle(color: c.faint),
                      prefixIcon: Icon(Icons.search_rounded, color: c.faint),
                      suffixIcon: _q.isEmpty
                          ? null
                          : IconButton(
                              icon: Icon(Icons.close_rounded, color: c.muted, size: 20),
                              onPressed: () {
                                _ctrl.clear();
                                _run('');
                              }),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          Expanded(
            child: _q.length < 2
                ? _empty(c)
                : ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      _section(c, 'APPS', _apps.length, [
                        for (final a in _apps)
                          _row(c, leading: appIcon(a, 40), title: a.label, onTap: () {
                            Navigator.pop(context);
                            widget.onLaunch(a);
                          }),
                      ]),
                      _section(c, 'PEOPLE', _people.length, [
                        for (final p in _people)
                          _row(c,
                              leading: PersonAvatar(name: p.name, person: p, size: 40),
                              title: p.name,
                              sub: p.number,
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                _round(Icons.call_rounded, VC.green, () => Native.call(p.number)),
                                _round(Icons.chat_rounded, VC.blurple, () => Native.whatsapp(p.number, '')),
                              ]),
                              onTap: () => Native.smsApp(p.number, '')),
                      ]),
                      _section(c, 'MESSAGES & NOTIFICATIONS', _chat.length, [
                        for (final m in _chat) _chatRow(c, m),
                      ]),
                      _section(c, 'SMS', _sms.length, [
                        for (final s in _sms)
                          _textRow(c,
                              key: s.hashCode,
                              icon: Icons.sms_rounded,
                              title: '${s['sent'] == true ? 'You → ' : ''}${_contactName(s['address'].toString())}',
                              body: s['body'].toString(),
                              time: (s['time'] as num?)?.toInt() ?? 0,
                              onTap: () => Native.smsApp(s['address'].toString(), '')),
                      ], extra: _perms['sms'] == true ? null : _permChip(c, 'Allow SMS search', () async {
                        await Native.requestSms();
                        final p = await Native.searchPerms();
                        if (mounted) setState(() => _perms = p);
                        _run(_q);
                      })),
                      _section(c, 'FILES', _files.length, [
                        for (final f in _files)
                          _row(c,
                              leading: _fileIcon(c, f['mime'].toString()),
                              title: f['name'].toString(),
                              sub: '${_size((f['size'] as num?)?.toInt() ?? 0)} · ${stamp(DateTime.fromMillisecondsSinceEpoch((f['time'] as num?)?.toInt() ?? 0))}',
                              onTap: () => Native.openFile(f['uri'].toString(), f['mime'].toString())),
                      ], extra: _perms['files'] == true ? null : _permChip(c, 'Allow searching documents & PDFs', () async {
                        await Native.requestFiles();
                      })),
                      _section(c, 'CALENDAR', _events.length, [
                        for (final e in _events)
                          _row(c,
                              leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(color: c.card, shape: BoxShape.circle),
                                  child: Icon(Icons.event_rounded, color: VC.blurple)),
                              title: e['title'].toString(),
                              sub: stamp(DateTime.fromMillisecondsSinceEpoch((e['begin'] as num?)?.toInt() ?? 0)),
                              onTap: () => Native.openEvent((e['id'] as num?)?.toInt() ?? 0)),
                      ]),
                      _section(c, 'REMINDERS', _sched.length, [
                        for (final r in _sched)
                          _row(c,
                              leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(color: VC.yellow.withValues(alpha: 0.18), shape: BoxShape.circle),
                                  child: const Icon(Icons.alarm_rounded, color: VC.yellow)),
                              title: r['type'] == 'message' ? 'Message ${r['name']}: ${r['text']}' : r['text'].toString(),
                              sub: stamp(DateTime.fromMillisecondsSinceEpoch((r['at'] as num?)?.toInt() ?? 0))),
                      ]),
                      _section(c, 'MEMORY', _mem.length, [
                        for (final f in _mem)
                          _row(c,
                              leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(color: c.card, shape: BoxShape.circle),
                                  child: Icon(Icons.psychology_rounded, color: VC.blurple)),
                              title: f),
                      ]),
                      _mailSection(c),
                      if (_total == 0)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text('Nothing on your phone matches "$_q".',
                              textAlign: TextAlign.center, style: TextStyle(color: c.faint)),
                        ),
                    ],
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _empty(VC c) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 0),
        child: Column(children: [
          Icon(Icons.manage_search_rounded, size: 56, color: c.faint),
          const SizedBox(height: 12),
          Text('Search everything', style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('Apps, people, your Vibe chat, notifications, SMS, files, calendar, reminders, memory and Gmail. '
              'Everything except Gmail is searched on your phone.',
              textAlign: TextAlign.center, style: TextStyle(color: c.muted, height: 1.4)),
        ]),
      );

  String _contactName(String number) {
    final d = number.replaceAll(RegExp(r'\D'), '');
    if (d.length < 7) return number;
    for (final p in People.all) {
      final pd = p.number.replaceAll(RegExp(r'\D'), '');
      if (pd.length >= 7 && pd.substring(pd.length - 7) == d.substring(d.length - 7)) return p.name;
    }
    return number;
  }

  String _size(int b) => b > 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : b > 1 << 10
          ? '${(b / (1 << 10)).round()} KB'
          : '$b B';

  Widget _fileIcon(VC c, String mime) {
    final i = mime.startsWith('image/')
        ? Icons.image_rounded
        : mime.startsWith('video/')
            ? Icons.movie_rounded
            : mime.startsWith('audio/')
                ? Icons.music_note_rounded
                : mime.contains('pdf')
                    ? Icons.picture_as_pdf_rounded
                    : Icons.description_rounded;
    return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(10)),
        child: Icon(i, color: c.muted));
  }

  Widget _round(IconData i, Color bg, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(8), child: Icon(i, color: Colors.white, size: 18)),
          ),
        ),
      );

  Widget _permChip(VC c, String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ActionChip(
            avatar: Icon(Icons.lock_open_rounded, size: 16, color: VC.blurple),
            label: Text(label),
            onPressed: onTap,
          ),
        ),
      );

  Widget _section(VC c, String title, int count, List<Widget> rows, {Widget? extra}) {
    if (count == 0 && extra == null) return const SizedBox.shrink();
    final open = _expanded.contains(title);
    final shown = open ? rows : rows.take(4).toList();
    return Stagger(
      index: 0,
      dy: 10,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Row(children: [
            Text(title,
                style: TextStyle(color: c.faint, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            if (count > 0) Text('  $count', style: TextStyle(color: c.faint, fontSize: 12)),
            const Spacer(),
            if (rows.length > 4)
              GestureDetector(
                onTap: () => setState(() => open ? _expanded.remove(title) : _expanded.add(title)),
                child: Text(open ? 'Less' : 'Show all',
                    style: TextStyle(color: VC.blurple, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
        ...shown,
        if (extra != null) extra,
      ]),
    );
  }

  /// Highlights the search words in a line of text.
  Widget _hl(VC c, String text, TextStyle style, {int maxLines = 1}) {
    final q = _q.toLowerCase();
    final spans = <TextSpan>[];
    var i = 0;
    final low = text.toLowerCase();
    while (q.isNotEmpty) {
      final j = low.indexOf(q, i);
      if (j < 0) break;
      if (j > i) spans.add(TextSpan(text: text.substring(i, j)));
      spans.add(TextSpan(
          text: text.substring(j, j + q.length),
          style: TextStyle(backgroundColor: VC.blurple.withValues(alpha: 0.28), fontWeight: FontWeight.w700)));
      i = j + q.length;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return Text.rich(TextSpan(style: style, children: spans), maxLines: maxLines, overflow: TextOverflow.ellipsis);
  }

  Widget _row(VC c,
      {required Widget leading, required String title, String? sub, Widget? trailing, VoidCallback? onTap}) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _hl(c, title, TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w600)),
                if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.faint, fontSize: 12)),
              ]),
            ),
            if (trailing != null) trailing,
          ]),
        ),
      ),
    );
  }

  /// A message line; private ones (OTPs, bank alerts) stay hidden until tapped.
  Widget _textRow(VC c,
      {required int key,
      required IconData icon,
      Widget? leading,
      required String title,
      required String body,
      required int time,
      VoidCallback? onTap}) {
    final private = Privacy.text(body) && !_revealed.contains(key);
    return Pressable(
      child: InkWell(
        onTap: private ? () => setState(() => _revealed.add(key)) : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            leading ??
                Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: c.card, shape: BoxShape.circle),
                    child: Icon(icon, color: c.muted, size: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w600))),
                  Text(stamp(DateTime.fromMillisecondsSinceEpoch(time)), style: TextStyle(color: c.faint, fontSize: 11)),
                ]),
                const SizedBox(height: 2),
                private
                    ? Text('🔒 Private message: tap to show', style: TextStyle(color: c.faint, fontStyle: FontStyle.italic))
                    : _hl(c, body, TextStyle(color: c.muted, fontSize: 14, height: 1.3), maxLines: 2),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _chatRow(VC c, Msg m) {
    final who = m.me ? prefs.name : m.isNotif ? (m.title?.isNotEmpty == true ? '${m.title} · ${m.app}' : m.app ?? '') : 'Vibe';
    AppEntry? app;
    for (final a in widget.apps) {
      if (a.pkg == m.pkg) app = a;
    }
    return _textRow(c,
        key: m.ts ^ m.text.hashCode,
        icon: m.me ? Icons.person_rounded : Icons.bolt_rounded,
        leading: app != null
            ? appIcon(app, 40)
            : m.me
                ? Avatar(name: prefs.name, size: 40, dot: false)
                : m.isNotif
                    ? null
                    : const BotAvatar(size: 40),
        title: who,
        body: m.text,
        time: m.ts,
        onTap: app != null
            ? () {
                Navigator.pop(context);
                widget.onLaunch(app!);
              }
            : null);
  }

  Widget _mailSection(VC c) {
    final rows = <Widget>[];
    if (!Mail.ready) {
      rows.add(_row(c,
          leading: _mailIcon(c),
          title: 'Search Gmail for "$_q"',
          sub: 'Opens Gmail',
          onTap: () => Native.openUrl(Mail.searchLink(_q))));
      if (widget.onMailSettings != null) {
        rows.add(_permChip(c, 'Set up mail search inside Vibe', () {
          Navigator.pop(context);
          widget.onMailSettings!();
        }));
      }
    } else if (_mailBusy) {
      rows.add(Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: VC.blurple)),
          const SizedBox(width: 12),
          Text('Searching Gmail…', style: TextStyle(color: c.muted)),
        ]),
      ));
    } else if (_mailError != null) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(_mailError!, style: const TextStyle(color: VC.red)),
      ));
    } else if (_mail == null) {
      rows.add(_row(c,
          leading: _mailIcon(c),
          title: 'Search Gmail for "$_q"',
          sub: 'Searches your whole mailbox',
          onTap: _searchMail));
    } else if (_mail!.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text('No mail matches "$_q".', style: TextStyle(color: c.faint)),
      ));
    } else {
      for (final h in _mail!) {
        rows.add(_textRow(c,
            key: h.msgId.hashCode,
            icon: Icons.mail_rounded,
            leading: _mailIcon(c),
            title: h.from,
            body: h.subject,
            time: _mailTime(h.date),
            onTap: () => Native.openUrl(h.link)));
      }
    }
    return _section(c, 'MAIL', _mail?.length ?? 0, rows, extra: const SizedBox.shrink());
  }

  int _mailTime(String date) {
    // e.g. "Sat, 10 Oct 2026 14:05:12 +0530"
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2})').firstMatch(date);
    if (m == null) return 0;
    const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final mi = mon.indexOf(m.group(2)!) + 1;
    return DateTime(int.parse(m.group(3)!), mi < 1 ? 1 : mi, int.parse(m.group(1)!), int.parse(m.group(4)!),
            int.parse(m.group(5)!))
        .millisecondsSinceEpoch;
  }

  Widget _mailIcon(VC c) => Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(color: Color(0xFFEA4335), shape: BoxShape.circle),
      child: const Icon(Icons.mail_rounded, color: Colors.white, size: 20));
}
