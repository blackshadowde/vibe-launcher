import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'chat.dart';
import 'gemini.dart';
import 'launcher.dart';
import 'main.dart';
import 'memory.dart';
import 'people.dart';
import 'privacy.dart';
import 'day.dart';
import 'sched.dart';
import 'profile_sheet.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// Home screen: a chat with Vibe. Tell it what to open.
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// App list panel: 0 = hidden, 1 = fully open. Follows your finger.
  late final AnimationController _dc =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  List<AppEntry> _apps = [];
  bool _isDefault = true;
  bool _loaded = false;
  bool _thinking = false;
  bool _online = true;
  String _nano = 'unknown'; // on-phone AI: available / downloadable / downloading / unavailable
  bool get _netOk => _online && !prefs.offlineMode;
  String? _attachImg; // picture waiting to be sent
  String? _attachText; // text or link shared from another app
  /// Messages already on screen when Vibe opened (or already animated): no entrance for them.
  final Set<String> _known = {};
  bool _firstPaint = true;
  String _idOf(Msg m) => '${m.ts}:${m.text.hashCode}:${m.me}';
  bool _notifAccess = true;
  Msg? _replyTo;
  List<Msg> _askedNotifs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.onHomePressed = _goHome;
    Native.onNotification = _onNotif;
    Native.onShared = _onShared;
    Native.onFired = _onFired;
    Native.onNet = (v) {
      if (!mounted || v == _online) return;
      setState(() => _online = v);
      if (v && !prefs.offlineMode) _drainQueue();
    };
    Native.nanoStatus().then((v) {
      if (mounted) setState(() => _nano = v);
    });
    Native.online().then((v) {
      if (!mounted) return;
      setState(() => _online = v);
      if (v && !prefs.offlineMode) _drainQueue();
    });
    if (prefs.brief) scheduleBrief();
    Native.takeShared().then((s) {
      if (s != null) _onShared(s);
    });
    chat.load();
    _known.addAll(chat.msgs.map(_idOf));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 800), () => _firstPaint = false);
    });
    if (chat.msgs.isEmpty) {
      chat.add(Msg(false,
          'Hi! I\'m Vibe, your launcher. Tell me what to open, like "open calendar" or just "calendar". '
          'Swipe in from the left edge to see all your apps. Type "help" anytime.'));
    }
    _input.addListener(() => setState(() {}));
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dc.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (People.all.isEmpty) People.load();
    final list = await Native.apps();
    final def = await Native.isDefault();
    final access = await Native.notifAccess();
    if (!mounted) return;
    setState(() {
      _apps = list;
      _isDefault = def;
      _notifAccess = access;
      _loaded = true;
    });
    for (final n in await Native.drainNotifs()) {
      _onNotif(n);
    }
    for (final f in await Native.takeFired()) {
      _onFired(f);
    }
  }

  void _goHome() {
    navKey.currentState?.popUntil((r) => r.isFirst);
    _closeDrawer();
    _focus.unfocus();
    _toBottom();
  }

  void _toBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  AppEntry? _byPkg(String p) {
    for (final a in _apps) {
      if (a.pkg == p) return a;
    }
    return null;
  }

  List<AppEntry> get _recent {
    final l = _apps
        .where((a) => prefs.lastUsed.containsKey(a.pkg) && !prefs.hidden.contains(a.pkg))
        .toList()
      ..sort((a, b) => prefs.lastUsed[b.pkg]!.compareTo(prefs.lastUsed[a.pkg]!));
    return l.take(8).toList();
  }

  Future<void> _launch(AppEntry a) async {
    prefs.tap();
    prefs.markUsed(a.pkg);
    _focus.unfocus();
    await Native.launch(a.pkg);
  }

  Future<void> _send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty && _attachImg == null && _attachText == null) return;
    _input.clear();
    prefs.tap();
    if (_attachImg != null || _attachText != null) {
      await _sendAttachment(text);
      return;
    }
    if (_replyTo != null) {
      await _sendReply(_replyTo!, text);
      return;
    }
    chat.add(Msg(true, text));
    _toBottom();

    final mem = memory.handle(text);
    if (mem != null) {
      await Future.delayed(const Duration(milliseconds: 250));
      _say(mem);
      return;
    }
    if (await _dayCommands(text)) return;
    if (await _schedule(text)) return;
    final cal = CalCmd.parse(text);
    if (cal != null) {
      await _calendar(cal);
      return;
    }
    final pc = People.parse(text);
    if (pc != null && await _people(pc)) return;
    if (isMissCmd(text) && await _whatDidIMiss()) return;
    final r = Brain.handle(text, _apps);
    if (!r.sure && (Gemini.enabled || _nano == 'available')) {
      await _askGemini(text);
    } else {
      await Future.delayed(const Duration(milliseconds: 250));
      await _doLocal(r);
    }
  }

  void _say(String text,
      {List<String> apps = const [], List<Map> links = const [], bool error = false, Map? card, bool local = false}) {
    chat.add(Msg(false, text, apps: apps, links: links, error: error, card: card, local: local));
    _toBottom();
  }

  Future<void> _pause() => Future.delayed(const Duration(milliseconds: 350));

  Future<void> _doLocal(Reply r) async {
    if (r.act == Act.clear) {
      chat.clear();
      _say('Chat cleared.');
      return;
    }
    _say(r.text, apps: r.app != null ? [r.app!.pkg] : r.choices.map((e) => e.pkg).toList());
    await _pause();
    if (!mounted) return;
    switch (r.act) {
      case Act.open:
        _launch(r.app!);
      case Act.drawer:
        _openDrawer();
      case Act.phoneSettings:
        _focus.unfocus();
        Native.openSettings();
      case Act.launcherSettings:
        _openLauncherSettings();
      case Act.media:
        if (!await Native.mediaControl(null, r.media)) {
          _say('Nothing is playing right now, or notification access is off.');
        }
      default:
        break;
    }
  }

  void _openDrawer() {
    _focus.unfocus();
    _dc.animateTo(1, curve: Curves.easeOutCubic);
  }

  void _closeDrawer() => _dc.animateBack(0, curve: Curves.easeOutCubic);

  double get _panelW => MediaQuery.of(context).size.width * 0.86;

  void _dragUpdate(DragUpdateDetails d) {
    if (_dc.value == 0 && (d.primaryDelta ?? 0) > 0) _focus.unfocus();
    _dc.value = (_dc.value + (d.primaryDelta ?? 0) / _panelW).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v > 300) {
      _openDrawer();
    } else if (v < -300) {
      _closeDrawer();
    } else {
      _dc.value > 0.5 ? _openDrawer() : _closeDrawer();
    }
  }

  void _openLauncherSettings() {
    _focus.unfocus();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  // ---------- Gemini ----------
  Future<void> _askGemini(String question, {String? imagePath, List<Msg>? history}) async {
    // No cloud key, or no internet: the on-phone AI answers if it can
    if (history == null && (!_netOk || !Gemini.enabled) && _nano == 'available') {
      if (await _askNano(question, imagePath: imagePath)) return;
    }
    if (!_netOk && history == null) {
      // No internet (or offline mode): park the question and answer it later
      final mine = chat.msgs.lastWhere((m) => m.me, orElse: () => Msg(true, question));
      prefs.setQueue([...prefs.queue, mine.ts]);
      await Future.delayed(const Duration(milliseconds: 250));
      _say(prefs.offlineMode
          ? '📴 Offline mode is on, so I\'ll answer this when you turn it off. Apps, calls, SMS, reminders and music still work.'
          : '📴 You\'re offline. I\'ll answer this as soon as you\'re back online.');
      return;
    }
    setState(() => _thinking = true);
    _toBottom();
    try {
      _askedNotifs = _ctxNotifs;
      final res = await Gemini.ask(history ?? chat.msgs, _apps, _askedNotifs, imagePath: imagePath);
      if (!mounted) return;
      if (res.error != null) {
        _say(res.error!, error: true);
        return;
      }
      if (res.calls.isEmpty) {
        _say(res.text.isEmpty ? '🤔' : res.text);
        return;
      }
      var preface = res.text;
      for (final call in res.calls) {
        await _runCall(call, preface, question);
        preface = '';
      }
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  Future<void> _runCall(Call call, String preface, String question) async {
    final a = call.args;
    String str(String k) => (a[k] ?? '').toString().trim();
    int toInt(String k, int d) => (a[k] is num) ? (a[k] as num).toInt() : int.tryParse(str(k)) ?? d;
    String say(String fallback) => preface.isNotEmpty ? preface : fallback;

    switch (call.name) {
      case 'open_app':
        final name = str('app_name');
        final found = Brain.match(Brain.norm(name), _apps);
        if (found.isEmpty) {
          _say('I couldn\'t find an app called "$name".');
          return;
        }
        final app = found.first.app;
        _say(say('Opening ${app.label}…'), apps: [app.pkg]);
        await _pause();
        _launch(app);
      case 'show_all_apps':
        _say(say('Here are all your apps.'));
        await _pause();
        _openDrawer();
      case 'open_settings':
        if (str('target') == 'launcher') {
          _say(say('Opening launcher settings…'));
          await _pause();
          _openLauncherSettings();
        } else {
          _say(say('Opening Settings…'));
          await _pause();
          Native.openSettings();
        }
      case 'web_search':
        final q = str('query');
        final res = await Gemini.search(q.isEmpty ? question : q, question);
        if (!mounted) return;
        if (res.error != null) {
          _say(res.error!, error: true);
        } else {
          _say(res.text.isEmpty ? 'I couldn\'t find anything on that.' : res.text,
              links: res.sources.map((s) => {'t': s.title, 'u': s.url}).toList());
        }
      case 'open_url':
        final url = str('url');
        _say(say('Opening the link…'), links: [{'t': Uri.tryParse(url)?.host ?? url, 'u': url}]);
        await _pause();
        Native.openUrl(url);
      case 'play_music':
        final q = str('query');
        _say(say('Playing $q…'));
        await _pause();
        if (!await Native.playMusic(q)) {
          _say('Your music app can\'t play by search, so I opened it on YouTube Music instead.');
          Native.openUrl('https://music.youtube.com/search?q=${Uri.encodeComponent(q)}');
        }
      case 'set_alarm':
        final h = toInt('hour', 7).clamp(0, 23), m = toInt('minute', 0).clamp(0, 59);
        final ok = await Native.setAlarm(h, m, str('label'));
        _say(ok
            ? say('Alarm set for ${clock(DateTime(2000, 1, 1, h, m))}.')
            : 'Your clock app didn\'t accept the alarm.');
      case 'set_timer':
        final secs = toInt('seconds', 60).clamp(1, 86400);
        final ok = await Native.setTimer(secs, str('label'));
        final mins = secs ~/ 60, rem = secs % 60;
        final len = mins == 0 ? '$rem sec' : rem == 0 ? '$mins min' : '$mins min $rem sec';
        _say(ok ? say('Timer set for $len.') : 'Your clock app didn\'t accept the timer.');
      case 'reply_notification':
        final n = _notifById(str('id'));
        final text = str('text');
        if (n == null || text.isEmpty) {
          _say('I couldn\'t find that conversation.');
          return;
        }
        if (preface.isNotEmpty) _say(preface);
        await _sendReply(n, text);
      case 'open_notification':
        final n = _notifById(str('id'));
        if (n == null) {
          _say('I couldn\'t find that notification.');
          return;
        }
        _say(say('Opening it…'));
        await _pause();
        _openNotif(n);
      case 'media_control':
        final action = str('action');
        if (preface.isNotEmpty) _say(preface);
        if (!await Native.mediaControl(null, action.isEmpty ? 'toggle' : action)) {
          _say('Nothing is playing right now, or notification access is off.');
        }
      case 'call_person':
        if (!await _people(PeopleCmd('call', name: str('name')), preface: preface)) {
          _say('I couldn\'t find "${str('name')}" in your contacts.');
        }
      case 'message_person':
        if (!await _people(
            PeopleCmd('message', name: str('name'), text: str('text'), via: str('via') == 'default' ? '' : str('via')),
            preface: preface)) {
          _say('I couldn\'t find "${str('name')}" in your contacts.');
        }
      case 'set_reminder':
        final at = DateTime.tryParse(str('time'));
        if (at == null || !at.isAfter(DateTime.now())) {
          _say('I couldn\'t work out when. Try "remind me at 6pm to…".');
        } else {
          await _addReminder(str('text').isEmpty ? 'Reminder' : str('text'), at, preface: preface);
        }
      case 'schedule_message':
        final at = DateTime.tryParse(str('time'));
        if (at == null || !at.isAfter(DateTime.now())) {
          _say('I couldn\'t work out when to send it.');
        } else if (!await _offerScheduledMessage(
            PeopleCmd('message', name: str('name'), text: str('text'), via: str('via') == 'default' ? '' : str('via')),
            at)) {
          _say('I couldn\'t find "${str('name')}" in your contacts.');
        }
      case 'list_reminders':
        await _listSched();
      case 'cancel_reminder':
        await _cancelByText(str('about'));
      case 'daily_brief':
        await _brief();
      case 'weather':
        await _weather(tomorrow: str('day') == 'tomorrow');
      case 'list_events':
        final d = DateTime.tryParse(str('date')) ?? DateTime.now();
        await _calendar(CalCmd('list', DateTime(d.year, d.month, d.day)));
      case 'add_event':
        final start = DateTime.tryParse(str('start'));
        if (start == null) {
          _say('I couldn\'t work out when that is.');
        } else {
          await _calendar(CalCmd('add', DateTime(start.year, start.month, start.day),
              title: str('title'), at: start),
              end: DateTime.tryParse(str('end')), location: str('location'));
        }
      case 'remember':
        final f = memory.add(str('fact'));
        _say(preface.isNotEmpty ? preface : 'Got it. I\'ll remember: $f');
      case 'forget':
        final gone = memory.forget(str('about'));
        _say(gone == null ? 'I couldn\'t find that in what I remember.' : 'Forgotten: $gone');
      case 'recent_calls':
        if (preface.isNotEmpty) _say(preface);
        await _showCalls();
      case 'clear_chat':
        chat.clear();
        _say('Chat cleared.');
      default:
        _say(preface.isEmpty ? 'I can\'t do that yet.' : preface);
    }
  }

  Msg? _notifById(String id) {
    final i = int.tryParse(id.replaceAll(RegExp(r'[^0-9]'), ''));
    if (i == null || i < 1 || i > _askedNotifs.length) return null;
    return _askedNotifs[i - 1];
  }

  // ---------- People ----------
  PeopleCmd? _pending; // waiting for you to pick which contact

  Map _contactMap(Person p) => {'id': p.id, 'name': p.name, 'number': p.number, 'photo': p.hasPhoto};

  Person _personOf(Map m) {
    for (final p in People.all) {
      if (p.id == m['id'] && p.number == m['number']) return p;
    }
    return Person((m['id'] ?? '').toString(), (m['name'] ?? '').toString(), (m['number'] ?? '').toString(),
        true, false, false, m['photo'] == true);
  }

  /// Handles call / message / call history. False = no such contact, let Vibe try something else.
  Future<bool> _people(PeopleCmd pc, {String preface = ''}) async {
    if (!await People.ensure()) {
      _say('I need permission to see your contacts for that. Allow it when Android asks, or in Vibe settings → People.',
          error: true);
      return true;
    }
    if (pc.action == 'calls') {
      if (preface.isNotEmpty) _say(preface);
      await _showCalls();
      return true;
    }
    final found = People.match(pc.name);
    if (found.isEmpty) return false;
    final best = found.first;
    final tie = found.length > 1 && found[1].score == best.score && found[1].p.id != best.p.id;
    if (best.score < 80 || tie) {
      _pending = pc;
      _say(preface.isNotEmpty ? preface : 'Which ${pc.name}?',
          card: {'type': 'people', 'items': found.take(4).map((e) => _contactMap(e.p)).toList()});
      return true;
    }
    await _doPeople(pc, best.p, preface);
    return true;
  }

  Future<void> _doPeople(PeopleCmd pc, Person p, String preface) async {
    _pending = null;
    final card = {'type': 'contact', ..._contactMap(p)};
    if (pc.action == 'call') {
      _say(preface.isNotEmpty ? preface : 'Calling ${p.name}…', card: card);
      await _pause();
      if (!await Native.call(p.number)) _say('Your phone didn\'t let me start the call.', error: true);
      return;
    }
    final via = pc.via.isNotEmpty ? pc.via : prefs.messenger;
    final text = pc.text.trim();
    if (via == 'whatsapp') {
      _say(text.isEmpty ? 'Opening WhatsApp chat with ${p.name}…' : 'Your message to ${p.name} is ready in WhatsApp. Tap Send.',
          card: card);
      await _pause();
      if (!await Native.whatsapp(p.number, text)) {
        _say('WhatsApp didn\'t open, so I opened Messages instead.');
        Native.smsApp(p.number, text);
      }
      return;
    }
    if (text.isEmpty) {
      _say('Opening Messages for ${p.name}…', card: card);
      await _pause();
      Native.smsApp(p.number, text);
      return;
    }
    // SMS goes out for real, so confirm first
    _say('Send this SMS?', card: {'type': 'sms', ..._contactMap(p), 'text': text, 'state': 'ready'});
  }

  Future<void> _showCalls() async {
    final calls = await Native.callLog(8);
    if (calls.isEmpty) {
      _say(People.perms['calls'] == true
          ? 'No recent calls.'
          : 'I need call log permission to see your calls. Allow it in Vibe settings → People.');
      return;
    }
    final missed = calls.where((e) => e['type'] == 'missed').length;
    _say(missed == 0 ? 'Your recent calls:' : 'Your recent calls ($missed missed):', card: {
      'type': 'calls',
      'items': calls
          .map((e) => {
                'name': (e['name'] ?? '').toString(),
                'number': (e['number'] ?? '').toString(),
                'type': e['type'],
                'time': e['time'],
              })
          .toList(),
    });
  }

  Future<void> _sendSmsCard(Msg m) async {
    final card = Map.from(m.card!);
    final ok = await Native.sendSms(card['number'].toString(), card['text'].toString());
    card['state'] = ok ? 'sent' : 'failed';
    chat.replace(m, Msg(false, m.text, ts: m.ts, card: card));
    if (!ok) _say('The SMS didn\'t go out. Check SMS permission in Vibe settings → People, or your SIM balance.', error: true);
  }

  void _contactSheet(Person p) {
    prefs.tap();
    final c = VC.of(context);
    Widget item(IconData i, String label, VoidCallback onTap) => ListTile(
          leading: Icon(i, color: c.text),
          title: Text(label, style: TextStyle(color: c.text, fontWeight: FontWeight.w500)),
          onTap: onTap,
        );
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          PersonAvatar(name: p.name, person: p, size: 72),
          const SizedBox(height: 10),
          Text(p.name, style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w800)),
          Text(p.number, style: TextStyle(color: c.muted, fontSize: 14)),
          const SizedBox(height: 8),
          item(Icons.call_rounded, 'Call', () {
            Navigator.pop(ctx);
            _doPeople(PeopleCmd('call', name: p.name), p, '');
          }),
          item(Icons.chat_rounded, 'WhatsApp', () {
            Navigator.pop(ctx);
            Native.whatsapp(p.number, '');
          }),
          item(Icons.sms_rounded, 'SMS', () {
            Navigator.pop(ctx);
            Native.smsApp(p.number, '');
          }),
          item(Icons.copy_rounded, 'Copy number', () {
            Navigator.pop(ctx);
            Clipboard.setData(ClipboardData(text: p.number));
          }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  /// Contact, contact choices, SMS confirmation and call history cards.
  Widget _card(VC c, Msg m) {
    final card = m.card!;
    BoxDecoration box() =>
        BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.divider));
    Widget personRow(Map d, {VoidCallback? onTap, Widget? trailing, String? sub}) {
      final p = _personOf(d);
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap ?? () => _contactSheet(p),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(children: [
            PersonAvatar(name: p.name.isEmpty ? p.number : p.name, person: p.id.isEmpty ? null : p, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name.isEmpty ? p.number : p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 15)),
                Text(sub ?? p.number, style: TextStyle(color: c.faint, fontSize: 12)),
              ]),
            ),
            if (trailing != null) trailing,
          ]),
        ),
      );
    }

    Widget round(IconData i, Color bg, VoidCallback onTap) => Padding(
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

    final state = (card['state'] ?? '').toString();
    Widget pill(String label, Color col) => Text(label, style: TextStyle(color: col, fontWeight: FontWeight.w700));
    DateTime atOf(Map d) => DateTime.fromMillisecondsSinceEpoch((d['at'] as num?)?.toInt() ?? 0);

    Widget weatherBox(Map w) => Row(children: [
          Text(w['emoji'].toString(), style: const TextStyle(fontSize: 34)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  w['now'] != null ? '${w['now']}° · ${w['desc']}' : '${w['desc']}',
                  style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 17)),
              Text('H ${w['max']}°  L ${w['min']}°  ·  🌧 ${w['rain']}%  ·  ${w['city']}',
                  style: TextStyle(color: c.muted, fontSize: 13)),
            ]),
          ),
        ]);
    Widget eventRow(Map e) {
      final b = DateTime.fromMillisecondsSinceEpoch((e['begin'] as num).toInt());
      final col = Color((e['color'] as num?)?.toInt() ?? 0xFF5865F2).withValues(alpha: 1);
      return InkWell(
        onTap: () => Native.openEvent((e['id'] as num?)?.toInt() ?? 0),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 4, height: 34, decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e['title'].toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 15)),
                Text(
                    [
                      e['allDay'] == true ? 'All day' : clock(b),
                      if ((e['location'] ?? '').toString().isNotEmpty) e['location'].toString(),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.faint, fontSize: 12)),
              ]),
            ),
          ]),
        ),
      );
    }

    Widget section(String title, List<Widget> kids) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(color: c.faint, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            const SizedBox(height: 4),
            ...kids,
          ]),
        );

    switch (card['type']) {
      case 'weather':
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          padding: const EdgeInsets.all(12),
          child: weatherBox(card),
        );
      case 'events':
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Column(children: [for (final e in List<Map>.from(card['items'] ?? const [])) eventRow(e)]),
        );
      case 'brief':
        final evs = List<Map>.from(card['events'] ?? const []);
        final rems = List<Map>.from(card['reminders'] ?? const []);
        final missed = List<Map>.from(card['missed'] ?? const []);
        final apps = List<Map>.from(card['apps'] ?? const []);
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: box(),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(card['date'].toString(),
                style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w800)),
            if (card['weather'] is Map) ...[const SizedBox(height: 10), weatherBox(card['weather'])],
            if (card['calAccess'] == true)
              section('📅  TODAY', [
                if (evs.isEmpty) Text('Nothing on your calendar. 🎉', style: TextStyle(color: c.muted)),
                for (final e in evs) eventRow(e),
              ]),
            if (rems.isNotEmpty)
              section('⏰  REMINDERS', [
                for (final r0 in rems)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                        '${clock(DateTime.fromMillisecondsSinceEpoch((r0['at'] as num).toInt()))}  ·  '
                        '${r0['type'] == 'message' ? 'Message ${r0['name']}' : r0['text']}',
                        style: TextStyle(color: c.text, fontSize: 14)),
                  ),
              ]),
            if (missed.isNotEmpty)
              section('📞  MISSED CALLS', [
                for (final mc in missed)
                  InkWell(
                    onTap: () => Native.call(mc['number'].toString()),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                              (mc['name'] ?? '').toString().isNotEmpty ? mc['name'].toString() : mc['number'].toString(),
                              style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
                        ),
                        Text(clock(DateTime.fromMillisecondsSinceEpoch((mc['time'] as num).toInt())),
                            style: TextStyle(color: c.faint, fontSize: 12)),
                        const SizedBox(width: 8),
                        const Icon(Icons.call_rounded, color: VC.green, size: 18),
                      ]),
                    ),
                  ),
              ]),
            if (apps.isNotEmpty)
              section('💬  WHILE YOU WERE AWAY', [
                Wrap(spacing: 8, runSpacing: 6, children: [
                  for (final a in apps)
                    Container(
                      padding: const EdgeInsets.fromLTRB(4, 3, 10, 3),
                      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(20)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _miniAvatar(c, a['pkg']?.toString(), 20),
                        const SizedBox(width: 6),
                        Text('${a['app']}  ${a['count']}',
                            style: TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                ]),
              ]),
            if (card['battery'] != null)
              section('🔋  PHONE', [
                Text('Battery ${card['battery']}%', style: TextStyle(color: c.text, fontSize: 14)),
              ]),
          ]),
        );
      case 'sched':
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: VC.yellow.withValues(alpha: 0.18), shape: BoxShape.circle),
              child: const Icon(Icons.alarm_rounded, color: VC.yellow, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(card['text'].toString(),
                    style: TextStyle(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        decoration: state == 'cancelled' ? TextDecoration.lineThrough : null)),
                Text(stamp(atOf(card)), style: TextStyle(color: c.faint, fontSize: 12)),
              ]),
            ),
            if (state == 'active')
              TextButton(
                onPressed: () async {
                  await Native.cancelSched(card['id'].toString());
                  _markSched(card['id'].toString(), 'cancelled');
                },
                child: const Text('Cancel', style: TextStyle(color: VC.red)),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: pill(state == 'done' ? '✓ Done' : 'Cancelled', state == 'done' ? VC.green : c.faint),
              ),
          ]),
        );
      case 'schedmsg':
        final at = atOf(card);
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            personRow(card, sub: '${card['via'] == 'sms' ? 'SMS' : 'WhatsApp'} · ${stamp(at)}'),
            if ((card['text'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text(card['text'].toString(), style: TextStyle(color: c.text, fontSize: 15, height: 1.35)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: state == 'ask'
                  ? Row(children: [
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: VC.blurple, minimumSize: const Size(0, 38)),
                          icon: const Icon(Icons.schedule_send_rounded, size: 18),
                          label: Text('Schedule · ${clock(at)}'),
                          onPressed: () => _confirmScheduledMessage(m),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
                        onPressed: () {
                          chat.replace(m, Msg(false, m.text, ts: m.ts, card: Map.from(card)..['state'] = 'now'));
                          _doPeople(
                              PeopleCmd('message', name: card['name'].toString(), text: card['text'].toString(),
                                  via: card['via'].toString()),
                              _personOf(card),
                              '');
                        },
                        child: Text('Send now', style: TextStyle(color: c.text)),
                      ),
                    ])
                  : Row(children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: state == 'scheduled'
                            ? pill(card['via'] == 'sms' ? '⏰ Sends ${When.label(at)}' : '⏰ I\'ll ping you ${When.label(at)}',
                                VC.yellow)
                            : state == 'done'
                                ? pill('✓ Done', VC.green)
                                : state == 'now'
                                    ? pill('Sent now instead', c.faint)
                                    : pill('Cancelled', c.faint),
                      ),
                      const Spacer(),
                      if (state == 'scheduled')
                        TextButton(
                          onPressed: () async {
                            await Native.cancelSched(card['id'].toString());
                            _markSched(card['id'].toString(), 'cancelled');
                          },
                          child: const Text('Cancel', style: TextStyle(color: VC.red)),
                        ),
                    ]),
            ),
          ]),
        );
      case 'sendnow':
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            personRow(card, sub: 'WhatsApp'),
            if ((card['text'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text(card['text'].toString(), style: TextStyle(color: c.text, fontSize: 15, height: 1.35)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: VC.green, minimumSize: const Size(0, 38)),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Open WhatsApp to send'),
                  onPressed: () => Native.whatsapp(card['number'].toString(), card['text'].toString()),
                ),
              ),
            ),
          ]),
        );
      case 'schedlist':
        final items = List<Map>.from(card['items'] ?? const []);
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          child: Column(children: [
            for (final d in items)
              ListTile(
                dense: true,
                leading: Icon(d['type'] == 'message' ? Icons.schedule_send_rounded : Icons.alarm_rounded,
                    color: VC.yellow),
                title: Text(
                    d['type'] == 'message' ? 'Message ${d['name']}: ${d['text']}' : d['text'].toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
                subtitle: Text(stamp(atOf(d)), style: TextStyle(color: c.faint, fontSize: 12)),
                trailing: IconButton(
                  icon: Icon(Icons.close_rounded, color: c.faint),
                  onPressed: () async {
                    await Native.cancelSched(d['id'].toString());
                    _markSched(d['id'].toString(), 'cancelled');
                    final left = items.where((e) => e['id'] != d['id']).toList();
                    chat.replace(m, Msg(false, left.isEmpty ? 'Nothing scheduled.' : m.text, ts: m.ts,
                        card: left.isEmpty ? null : (Map.from(card)..['items'] = left)));
                  },
                ),
              ),
          ]),
        );
      case 'contact':
        final p = _personOf(card);
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          child: personRow(card,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                round(Icons.call_rounded, VC.green, () => _doPeople(PeopleCmd('call', name: p.name), p, '')),
                round(Icons.chat_rounded, VC.blurple, () => _startReply(m)),
              ])),
        );
      case 'people':
        final items = List<Map>.from(card['items'] ?? const []);
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          child: Column(children: [
            for (final d in items)
              personRow(d, onTap: () {
                final pc = _pending;
                final p = _personOf(d);
                if (pc != null) {
                  _doPeople(pc, p, '');
                } else {
                  _contactSheet(p);
                }
              }),
          ]),
        );
      case 'sms':
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            personRow(card, sub: 'SMS · ${card['number']}'),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(card['text'].toString(), style: TextStyle(color: c.text, fontSize: 15, height: 1.35)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: state == 'ready'
                  ? Row(children: [
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: VC.green, minimumSize: const Size(0, 38)),
                          icon: const Icon(Icons.send_rounded, size: 18),
                          label: const Text('Send'),
                          onPressed: () => _sendSmsCard(m),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
                          onPressed: () {
                            final cc = Map.from(card)..['state'] = 'cancelled';
                            chat.replace(m, Msg(false, m.text, ts: m.ts, card: cc));
                          },
                          child: Text('Cancel', style: TextStyle(color: c.text)),
                        ),
                      ),
                    ])
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
                      child: Text(
                        state == 'sent' ? '✓ Sent' : state == 'failed' ? '✕ Not sent' : 'Cancelled',
                        style: TextStyle(
                            color: state == 'sent' ? VC.green : state == 'failed' ? VC.red : c.faint,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
            ),
          ]),
        );
      case 'calls':
        final items = List<Map>.from(card['items'] ?? const []);
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: box(),
          child: Column(children: [
            for (final d in items)
              Builder(builder: (_) {
                final type = d['type'];
                final icon = type == 'outgoing'
                    ? Icons.call_made_rounded
                    : type == 'missed' || type == 'rejected'
                        ? Icons.call_missed_rounded
                        : Icons.call_received_rounded;
                final col = type == 'missed' || type == 'rejected' ? VC.red : type == 'outgoing' ? c.muted : VC.green;
                final number = d['number'].toString();
                Person? known;
                final digits = number.replaceAll(RegExp(r'\D'), '');
                for (final p in People.all) {
                  final pd = p.number.replaceAll(RegExp(r'\D'), '');
                  if (digits.length >= 7 && pd.length >= 7 &&
                      pd.substring(pd.length - 7) == digits.substring(digits.length - 7)) {
                    known = p;
                    break;
                  }
                }
                final name = d['name'].toString().isNotEmpty ? d['name'].toString() : (known?.name ?? '');
                final row = {
                  'id': known?.id ?? '',
                  'name': name,
                  'number': number,
                  'photo': known?.hasPhoto ?? false,
                };
                return personRow(row,
                    sub: stamp(DateTime.fromMillisecondsSinceEpoch((d['time'] as num?)?.toInt() ?? 0)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, size: 18, color: col),
                      round(Icons.call_rounded, VC.green, () => Native.call(number)),
                    ]));
              }),
          ]),
        );
    }
    return const SizedBox.shrink();
  }

  // ---------- Pictures and things shared to Vibe ----------
  void _onShared(Map s) {
    final text = [s['subject'], s['text']].whereType<String>().where((e) => e.trim().isNotEmpty).join('\n');
    _closeDrawer();
    navKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {
      _replyTo = null;
      _attachImg = s['image']?.toString();
      _attachText = text.isEmpty ? null : text;
    });
    _focus.requestFocus();
  }

  void _plusMenu() {
    _focus.unfocus();
    final c = VC.of(context);
    Widget tile(IconData i, Color col, String label, VoidCallback onTap) => Expanded(
          child: Pressable(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: col, shape: BoxShape.circle),
                    child: Icon(i, color: Colors.white, size: 28),
                  ),
                  const SizedBox(height: 8),
                  Text(label, style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        );
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Row(children: [
            tile(Icons.photo_camera_rounded, VC.blurple, 'Camera', () {
              Navigator.pop(ctx);
              _pick(ImageSource.camera);
            }),
            tile(Icons.photo_library_rounded, VC.green, 'Photos', () {
              Navigator.pop(ctx);
              _pick(ImageSource.gallery);
            }),
            tile(Icons.apps_rounded, const Color(0xFFEB459E), 'Apps', () {
              Navigator.pop(ctx);
              _openDrawer();
            }),
          ]),
        ),
      ),
    );
  }

  Future<void> _pick(ImageSource src) async {
    try {
      final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 85);
      if (x == null) return;
      final dir = await Native.filesDir();
      final path = '$dir/img_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(x.path).copy(path);
      if (!mounted) return;
      setState(() {
        _replyTo = null;
        _attachImg = path;
      });
      _focus.requestFocus();
    } catch (_) {
      _say('I couldn\'t open the ${src == ImageSource.camera ? 'camera' : 'photos'}.', error: true);
    }
  }

  Widget _attachBar(VC c) {
    final img = _attachImg;
    final txt = _attachText;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        if (img != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(img), width: 52, height: 52, fit: BoxFit.cover, cacheWidth: 160),
          )
        else
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.link_rounded, color: c.muted),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(img != null ? 'Photo' : 'Shared with Vibe',
                style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 14)),
            Text(txt ?? 'Ask anything about it, or just send',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.muted, fontSize: 13)),
          ]),
        ),
        InkWell(
          customBorder: const CircleBorder(),
          onTap: () => setState(() {
            _attachImg = null;
            _attachText = null;
          }),
          child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.close_rounded, size: 20, color: c.muted)),
        ),
      ]),
    );
  }

  Future<void> _sendAttachment(String typed) async {
    final img = _attachImg;
    final shared = _attachText;
    setState(() {
      _attachImg = null;
      _attachText = null;
    });
    final question = typed.isNotEmpty
        ? typed
        : img != null
            ? 'What\'s in this picture?'
            : 'Summarise this for me.';
    chat.add(Msg(true, question,
        img: img,
        quote: shared,
        quoteName: shared == null ? null : 'Shared',
        quotePkg: shared == null ? null : 'me'));
    _toBottom();
    if (!Gemini.enabled) {
      await Future.delayed(const Duration(milliseconds: 250));
      _say('Add a Gemini key in Vibe settings and I can look at pictures and read what you share.');
      return;
    }
    await _askGemini(question, imagePath: img);
  }

  void _viewImage(String path) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, _, __) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        child: Center(child: InteractiveViewer(maxScale: 5, child: Image.file(File(path)))),
      ),
      transitionBuilder: (ctx, a, _, child) => FadeTransition(opacity: a, child: child),
    );
  }

  // ---------- On-phone AI (Gemini Nano) ----------
  String _nanoPrompt(String question, {String extra = ''}) {
    final b = StringBuffer()
      ..writeln('You are Vibe, a friendly assistant built into the user\'s phone launcher.')
      ..writeln('Reply briefly and naturally, in the same language the user writes in. You cannot browse the internet.')
      ..writeln('User\'s name: ${prefs.name}. Now: ${stamp(DateTime.now())}.');
    if (memory.facts.isNotEmpty) {
      b.writeln('Things the user asked you to remember:');
      for (final f in memory.facts.take(30)) {
        b.writeln('- $f');
      }
    }
    if (extra.isNotEmpty) b.writeln(extra);
    final talk = chat.msgs.where((m) => !m.isNotif && !m.error && m.text.trim().isNotEmpty && m.card == null).toList();
    final recent = talk.length > 10 ? talk.sublist(talk.length - 10) : talk;
    b.writeln('\nConversation:');
    for (final m in recent) {
      if (m.me && m.text == question && m == recent.last) continue;
      final t = m.text.length > 400 ? '${m.text.substring(0, 400)}…' : m.text;
      b.writeln('${m.me ? 'User' : 'Vibe'}: $t');
    }
    b.writeln('User: $question');
    b.write('Vibe:');
    var p = b.toString();
    if (p.length > 9000) p = p.substring(p.length - 9000);
    return p;
  }

  /// Answers on the phone. False if the on-phone AI couldn't.
  Future<bool> _askNano(String question, {String? imagePath, String extra = ''}) async {
    setState(() => _thinking = true);
    _toBottom();
    final text = await Native.nanoAsk(_nanoPrompt(question, extra: extra), image: imagePath);
    if (mounted) setState(() => _thinking = false);
    if (text == null || text.trim().isEmpty) return false;
    _say(text.trim(), local: true);
    return true;
  }

  /// "What did I miss?": summarised on the phone when possible, so private notifications stay private.
  Future<bool> _whatDidIMiss() async {
    final since = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    final notifs = chat.msgs.reversed.where((m) => m.isNotif && !m.media && m.ts > since).take(40).toList();
    if (notifs.isEmpty) {
      _say('Nothing new in the last 24 hours. 🎉');
      return true;
    }
    if (_nano == 'available') {
      final list = notifs
          .map((m) => '- ${clock(DateTime.fromMillisecondsSinceEpoch(m.ts))} ${m.app}'
              '${(m.title ?? '').isEmpty ? '' : ' / ${m.title}'}: '
              '${m.text.length > 160 ? '${m.text.substring(0, 160)}…' : m.text}')
          .join('\n');
      final ok = await _askNano('What did I miss? Summarise these notifications in a few short lines, '
          'most important first. Never repeat OTP codes or full account numbers.',
          extra: 'Notifications from the last 24 hours (newest first):\n$list');
      if (ok) return true;
    }
    if (Gemini.enabled && _netOk) return false; // let Gemini answer with private ones filtered out
    // No AI available: a simple count per app
    final counts = <String, int>{};
    for (final m in notifs) {
      counts[m.app ?? m.pkg!] = (counts[m.app ?? m.pkg!] ?? 0) + 1;
    }
    final lines = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(8)
        .map((e) => '• ${e.key}: ${e.value}')
        .join('\n');
    _say('In the last 24 hours:\n$lines');
    return true;
  }

  // ---------- Offline queue & offline mode ----------
  bool _draining = false;

  /// Back online: answer the questions asked while offline, each as a reply to the original.
  Future<void> _drainQueue() async {
    if (_draining || prefs.queue.isEmpty || !Gemini.enabled) return;
    _draining = true;
    final waiting = [...prefs.queue];
    prefs.setQueue([]);
    _say(waiting.length == 1
        ? '📶 Back online. Answering what you asked earlier.'
        : '📶 Back online. Answering your ${waiting.length} earlier questions.');
    for (final ts in waiting) {
      final i = chat.msgs.indexWhere((m) => m.me && m.ts == ts);
      if (i < 0) continue;
      final q = chat.msgs[i];
      chat.add(Msg(false, '', quote: q.text, quoteName: prefs.name, quotePkg: 'me'));
      await _askGemini(q.text, imagePath: q.img, history: chat.msgs.sublist(0, i + 1));
    }
    _draining = false;
  }

  void _setOffline(bool on) {
    prefs.setOfflineMode(on);
    if (on) {
      _say('📴 Offline mode on. I won\'t use any internet. Apps, calls, SMS, reminders, calendar and music all still work, '
          'and anything that needs Gemini waits until you turn it off.');
    } else {
      _say('Offline mode off.');
      Native.online().then((v) {
        setState(() => _online = v);
        if (v) _drainQueue();
      });
    }
  }

  // ---------- Daily brief, weather, calendar ----------
  Future<bool> _dayCommands(String text) async {
    final off = RegExp(r'^(?:turn\s+)?(?:offline|data saver|no internet)\s*mode\s*(on|off)?$|^(?:turn\s+)?(on|off)\s+(?:offline|data saver)\s*mode$',
            caseSensitive: false)
        .firstMatch(text.trim());
    if (off != null) {
      final w = (off.group(1) ?? off.group(2))?.toLowerCase();
      _setOffline(w == null ? !prefs.offlineMode : w == 'on');
      return true;
    }
    if (isBriefCmd(text)) {
      await _brief();
      return true;
    }
    if (isWeatherCmd(text)) {
      await _weather(tomorrow: text.toLowerCase().contains('tomorrow'));
      return true;
    }
    final city = RegExp(r"^(?:my city is|i live in|set (?:my )?city(?: to)?)\s+(.+?)\W*$", caseSensitive: false)
        .firstMatch(text.trim());
    if (city != null) {
      await _setCity(city.group(1)!);
      return true;
    }
    return false;
  }

  Future<void> _setCity(String name) async {
    if (!_netOk) {
      _say('I need internet to look up "$name". Try again when you\'re online.');
      return;
    }
    setState(() => _thinking = true);
    final g = await Weather.geocode(name);
    if (mounted) setState(() => _thinking = false);
    if (g == null) {
      _say('I couldn\'t find "$name". Check the spelling, or try a nearby bigger city.', error: true);
      return;
    }
    prefs.setCity(g.$1, g.$2, g.$3);
    _say('Got it, your city is ${g.$1}. I\'ll use it for the weather.');
  }

  Future<void> _weather({bool tomorrow = false}) async {
    if (!_netOk) {
      _say(prefs.offlineMode ? '📴 Weather needs internet, and offline mode is on.' : '📴 Weather needs internet. You\'re offline.');
      return;
    }
    if (prefs.lat == null) {
      _say('Tell me your city first, like "my city is Mumbai".');
      return;
    }
    setState(() => _thinking = true);
    final w = await Weather.fetch();
    if (mounted) setState(() => _thinking = false);
    if (w == null) {
      _say('I couldn\'t get the weather right now. Are you online?', error: true);
      return;
    }
    _say(tomorrow ? 'Tomorrow in ${prefs.city.split(',').first}:' : 'Right now in ${prefs.city.split(',').first}:',
        card: w.toCard(tomorrow: tomorrow));
  }

  Future<bool> _calendarAccess() async {
    if (await Native.calPerms()) return true;
    await Native.requestCalendar();
    return Native.calPerms();
  }

  Future<void> _calendar(CalCmd cmd, {DateTime? end, String location = ''}) async {
    if (cmd.action == 'list') {
      if (!await _calendarAccess()) {
        _say('I need calendar permission to see your plans.', error: true);
        return;
      }
      final from = cmd.day, to = cmd.day.add(const Duration(days: 1));
      final evs = await Native.events(from, to);
      final label = dayLabel(cmd.day);
      if (evs.isEmpty) {
        _say('Nothing on your calendar ${label == 'Today' || label == 'Tomorrow' ? label.toLowerCase() : 'on $label'}. 🎉');
        return;
      }
      _say('${label == 'Today' || label == 'Tomorrow' ? label : label}: ${evs.length} ${evs.length == 1 ? 'thing' : 'things'}',
          card: {'type': 'events', 'items': evs});
      return;
    }
    final start = cmd.at!;
    final finish = (end != null && end.isAfter(start)) ? end : start.add(const Duration(hours: 1));
    await _calendarAccess();
    final res = await Native.addEvent(cmd.title, start, finish, location: location);
    if (res.startsWith('added')) {
      _say('📅 Added to your calendar:', card: {
        'type': 'events',
        'items': [
          {
            'id': int.tryParse(res.split(':').last) ?? 0,
            'title': cmd.title,
            'begin': start.millisecondsSinceEpoch,
            'end': finish.millisecondsSinceEpoch,
            'allDay': false,
            'location': location,
            'color': 0xFF5865F2,
          }
        ],
      });
    } else if (res == 'opened') {
      _say('I opened your calendar with "${cmd.title}" on ${stamp(start)} filled in. Tap Save.');
    } else {
      _say('I couldn\'t add that. Is there a calendar app on this phone?', error: true);
    }
  }

  /// The daily brief: one message with everything that matters this morning.
  Future<void> _brief() async {
    setState(() => _thinking = true);
    final now = DateTime.now();
    final since = prefs.lastBrief > 0 && now.millisecondsSinceEpoch - prefs.lastBrief < 36 * 3600 * 1000
        ? prefs.lastBrief
        : now.subtract(const Duration(hours: 12)).millisecondsSinceEpoch;
    final start = DateTime(now.year, now.month, now.day), end = start.add(const Duration(days: 1));

    final weather = _netOk ? await Weather.fetch() : null;
    final evs = await Native.calPerms() ? await Native.events(start, end) : <Map>[];
    final rems = (await Native.listSched())
        .where((e) => e['type'] != 'brief' && ((e['at'] as num?) ?? 0) < end.millisecondsSinceEpoch)
        .toList()
      ..sort((a, b) => ((a['at'] as num?) ?? 0).compareTo((b['at'] as num?) ?? 0));
    final calls = People.perms['calls'] == true
        ? (await Native.callLog(30))
            .where((e) => e['type'] == 'missed' && ((e['time'] as num?) ?? 0) > since)
            .map((e) => {'name': e['name'], 'number': e['number'], 'time': e['time']})
            .toList()
        : <Map>[];
    final counts = <String, int>{}, names = <String, String>{};
    for (final m in chat.msgs) {
      if (m.isNotif && !m.media && m.ts > since) {
        counts[m.pkg!] = (counts[m.pkg!] ?? 0) + 1;
        names[m.pkg!] = m.app ?? m.pkg!;
      }
    }
    final apps = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(5)
        .map((e) => {'pkg': e.key, 'app': names[e.key], 'count': e.value})
        .toList();
    final dev = await Native.deviceInfo();
    prefs.markBrief();
    if (mounted) setState(() => _thinking = false);

    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
      'October', 'November', 'December'];
    final hi = now.hour < 12 ? 'Good morning' : now.hour < 17 ? 'Good afternoon' : 'Good evening';
    final first = prefs.name == 'You' ? '' : ', ${prefs.name.split(' ').first}';
    _say('$hi$first! Here\'s your day.', card: {
      'type': 'brief',
      'date': '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}',
      if (weather != null) 'weather': weather.toCard(),
      'calendar': prefs.lat != null || evs.isNotEmpty ? true : evs.isNotEmpty,
      'calAccess': await Native.calPerms(),
      'events': evs.take(6).toList(),
      'reminders': rems.take(5).toList(),
      'missed': calls.take(5).toList(),
      'apps': apps,
      'battery': dev['battery'],
    });
  }

  // ---------- Reminders & scheduled messages ----------
  /// Handles "remind me…", "my reminders", and messages/calls with a time in them. False = not for us.
  Future<bool> _schedule(String text) async {
    if (isListCmd(text)) {
      await _listSched();
      return true;
    }
    final rc = ReminderCmd.parse(text);
    if (rc != null) {
      if (rc.at == null) {
        if (Gemini.enabled) return false; // Gemini is better with tricky times
        _say('When should I remind you? Try "remind me at 6pm to call mom" or "remind me in 20 minutes".');
        return true;
      }
      await _addReminder(rc.text, rc.at!);
      return true;
    }
    final w = When.find(text);
    if (w == null) return false;
    final pc = People.parse(w.rest);
    if (pc == null || pc.action == 'calls') return false;
    if (pc.action == 'call') {
      if (!await People.ensure()) return false;
      final found = People.match(pc.name);
      if (found.isEmpty) return false;
      await _addReminder('Call ${found.first.p.name}', w.at);
      return true;
    }
    return _offerScheduledMessage(pc, w.at);
  }

  Future<void> _addReminder(String text, DateTime at, {String preface = ''}) async {
    final id = 'r${DateTime.now().millisecondsSinceEpoch}';
    final exact = await Native.schedule({'id': id, 'type': 'reminder', 'at': at.millisecondsSinceEpoch, 'text': text});
    Native.requestPostNotif();
    _say(preface.isNotEmpty ? preface : 'I\'ll remind you ${When.label(at)}.',
        card: {'type': 'sched', 'id': id, 'kind': 'reminder', 'text': text, 'at': at.millisecondsSinceEpoch, 'state': 'active'});
    if (!exact) {
      _say('Your phone may ring it a few minutes late. Allow "Alarms & reminders" for Vibe in Android settings for exact timing.');
    }
  }

  /// Asks first: schedule for later, or send now? (The time might be part of the message.)
  Future<bool> _offerScheduledMessage(PeopleCmd pc, DateTime at) async {
    if (!await People.ensure()) {
      _say('I need permission to see your contacts for that.', error: true);
      return true;
    }
    final found = People.match(pc.name);
    if (found.isEmpty) return false;
    final p = found.first.p;
    final via = pc.via.isNotEmpty ? pc.via : prefs.messenger;
    _say('Schedule this message?', card: {
      'type': 'schedmsg',
      ..._contactMap(p),
      'text': pc.text,
      'via': via,
      'at': at.millisecondsSinceEpoch,
      'state': 'ask',
    });
    return true;
  }

  Future<void> _confirmScheduledMessage(Msg m) async {
    final card = Map.from(m.card!);
    final id = 's${DateTime.now().millisecondsSinceEpoch}';
    await Native.schedule({
      'id': id,
      'type': 'message',
      'at': card['at'],
      'text': card['text'],
      'name': card['name'],
      'number': card['number'],
      'via': card['via'],
    });
    Native.requestPostNotif();
    card['state'] = 'scheduled';
    card['id'] = id;
    chat.replace(m, Msg(false, m.text, ts: m.ts, card: card));
  }

  Future<void> _listSched() async {
    final items = (await Native.listSched()).toList()
      ..sort((a, b) => ((a['at'] as num?) ?? 0).compareTo((b['at'] as num?) ?? 0));
    if (items.isEmpty) {
      _say('Nothing scheduled.');
      return;
    }
    _say('Coming up:', card: {'type': 'schedlist', 'items': items});
  }

  Future<void> _cancelByText(String about) async {
    final words = Brain.norm(about).split(' ').where((w) => w.length > 2).toSet();
    final items = await Native.listSched();
    Map? best;
    var bestScore = 0;
    for (final it in items) {
      final t = Brain.norm('${it['text']} ${it['name'] ?? ''}').split(' ').toSet();
      final sc = words.where(t.contains).length;
      if (sc > bestScore) {
        best = it;
        bestScore = sc;
      }
    }
    if (best == null) {
      _say('I couldn\'t find that reminder.');
      return;
    }
    await Native.cancelSched(best['id'].toString());
    _markSched(best['id'].toString(), 'cancelled');
    _say('Cancelled: ${best['text']}');
  }

  /// Updates the original card (e.g. to "Done" or "Cancelled").
  void _markSched(String id, String state) {
    for (final m in chat.msgs.reversed) {
      if (m.card?['id'] == id) {
        chat.replace(m, Msg(false, m.text, ts: m.ts, card: Map.from(m.card!)..['state'] = state));
        return;
      }
    }
  }

  void _onFired(Map f) {
    if (f['type'] == 'brief') {
      _brief();
      return;
    }
    final id = f['id']?.toString() ?? '';
    _markSched(id, 'done');
    final text = (f['text'] ?? '').toString();
    final name = (f['name'] ?? '').toString();
    if (f['type'] == 'message') {
      if (f['via'] == 'sms') {
        f['sent'] == true
            ? _say('✓ Sent your scheduled SMS to $name: "$text"')
            : _say('Your scheduled SMS to $name didn\'t go out.', error: true);
      } else {
        _say('💬 Time to send your message to $name.', card: {
          'type': 'sendnow',
          'id': f['id'],
          'name': name,
          'number': f['number'],
          'text': text,
          'state': 'ask',
        });
      }
    } else {
      _say('⏰ $text');
    }
  }

  Future<void> _voice() async {
    prefs.tap();
    final t = await Native.listen();
    if (t != null && t.trim().isNotEmpty) _send(t);
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([prefs, chat]),
      builder: (context, _) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: (c.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
        child: PopScope(
          canPop: false, // Back never closes the launcher
          onPopInvokedWithResult: (_, __) {
            if (_replyTo != null) {
              setState(() => _replyTo = null);
            } else if (_dc.value > 0) {
              _closeDrawer();
            } else {
              _goHome();
            }
          },
          child: Scaffold(
            backgroundColor: c.chat,
            body: Stack(children: [
              // Swipe right anywhere on the chat to pull the app list in
              GestureDetector(
                onHorizontalDragUpdate: _dragUpdate,
                onHorizontalDragEnd: _dragEnd,
                child: SafeArea(
                  child: Column(children: [
                    _header(c),
                    if (!_isDefault && _loaded) _defaultBanner(),
                    if (_isDefault && !_notifAccess && _loaded && prefs.showNotifs) _notifBanner(),
                    Expanded(child: _timeline(c)),
                    _inputBar(c),
                  ]),
                ),
              ),
              AnimatedBuilder(
                animation: _dc,
                builder: (context, _) {
                  if (_dc.value == 0) return const SizedBox.shrink();
                  final w = _panelW;
                  return Stack(children: [
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: _closeDrawer,
                        onHorizontalDragUpdate: _dragUpdate,
                        onHorizontalDragEnd: _dragEnd,
                        child: ColoredBox(color: Colors.black.withValues(alpha: 0.5 * _dc.value)),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      bottom: 0,
                      left: -w * (1 - _dc.value),
                      width: w,
                      child: GestureDetector(
                        onHorizontalDragUpdate: _dragUpdate,
                        onHorizontalDragEnd: _dragEnd,
                        child: _AppDrawer(apps: _apps, loaded: _loaded, onLaunch: (a) {
                          _closeDrawer();
                          _launch(a);
                        }),
                      ),
                    ),
                  ]);
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------- top bar: you + settings ----------
  /// Top bar like Vibe's chat screen: big round avatar, bold name, status line, no divider.
  Widget _header(VC c) {
    String status = 'Online';
    if (prefs.offlineMode || !_online) {
      final q = prefs.queue.length;
      status = '${prefs.offlineMode ? '📴 Offline mode' : '📴 Offline'}${q > 0 ? ' · $q waiting' : ''}';
    } else for (final m in chat.msgs.reversed) {
      if (m.media) {
        if (m.text.startsWith('▶')) {
          final song = RegExp(r'"(.+?)"').firstMatch(m.text)?.group(1);
          if (song != null && DateTime.now().millisecondsSinceEpoch - m.ts < 60 * 60 * 1000) {
            status = '🎵 Listening to $song';
          }
        }
        break;
      }
    }
    return SizedBox(
      height: 64,
      child: InkWell(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        onTap: () { prefs.tap(); showProfileSheet(context); },
        // Hidden shortcut: long-press yourself for Vibe settings
        onLongPress: () { prefs.heavy(); _openLauncherSettings(); },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(children: [
            Pressable(child: Avatar(name: prefs.name, size: 40)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(prefs.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 19)),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(status,
                        key: ValueKey(status),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.muted, fontSize: 13)),
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _notifBanner() => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(color: VC.blurple, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          const Expanded(
            child: Text('Get your notifications here as messages',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            style: TextButton.styleFrom(
                backgroundColor: Colors.white, foregroundColor: VC.blurple,
                minimumSize: const Size(0, 32)),
            onPressed: Native.openNotifAccess,
            child: const Text('Allow'),
          ),
        ]),
      );

  Widget _defaultBanner() => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(color: VC.blurple, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          const Expanded(
            child: Text('Make Vibe your Home app',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            style: TextButton.styleFrom(
                backgroundColor: Colors.white, foregroundColor: VC.blurple,
                minimumSize: const Size(0, 32)),
            onPressed: Native.openHomeSettings,
            child: const Text('Set'),
          ),
        ]),
      );

  // ---------- messages ----------
  Widget _timeline(VC c) {
    final msgs = chat.msgs;
    final n = msgs.length;
    return GestureDetector(
      onTap: () => _focus.unfocus(),
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        itemCount: n + (_thinking ? 1 : 0),
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          for (var i = 0; i < n; i++) {
            if (_idOf(msgs[n - 1 - i]) == key.value) return i + (_thinking ? 1 : 0);
          }
          return null;
        },
        itemBuilder: (_, idx) {
          if (_thinking && idx == 0) {
            return const Entrance(key: ValueKey('typing'), animate: true, child: _TypingRowHolder());
          }
          final i = _thinking ? idx - 1 : idx;
          final m = msgs[n - 1 - i];
          final older = n - 2 - i >= 0 ? msgs[n - 2 - i] : null;
          final t = DateTime.fromMillisecondsSinceEpoch(m.ts);
          final ot = older == null ? null : DateTime.fromMillisecondsSinceEpoch(older.ts);
          final newDay = ot == null || !sameDay(ot, t);
          final head =
              newDay || m.quote != null || older!.sender != m.sender || m.ts - older.ts > 5 * 60 * 1000;
          final id = _idOf(m);
          final isNew = _known.add(id) && !_firstPaint;
          Widget row = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (newDay) _dayDivider(c, t),
            _message(c, m, t, head),
          ]);
          row = isNew
              ? Entrance(animate: true, fromRight: false, child: row)
              : _firstPaint
                  ? Stagger(index: i, child: row)
                  : row;
          return KeyedSubtree(key: ValueKey(id), child: row);
        },
      ),
    );
  }

  // ignore: unused_element
  Widget _typingRow(VC c) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Row(children: [
          const BotAvatar(size: 24),
          const SizedBox(width: 8),
          const TypingDots(),
          const SizedBox(width: 8),
          Text('Vibe is typing…', style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _dayDivider(VC c, DateTime t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Row(children: [
          Expanded(child: Divider(color: c.divider, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(dayLabel(t),
                style: TextStyle(color: c.faint, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Divider(color: c.divider, height: 1)),
        ]),
      );

  /// Small avatar for a reply strip or quote.
  Widget _miniAvatar(VC c, String? who, double size) {
    if (who == 'vibe') return BotAvatar(size: size);
    if (who == 'me' || who == null) return Avatar(name: prefs.name, size: size, dot: false);
    final a = _byPkg(who);
    if (a != null) return appIcon(a, size);
    return CircleAvatar(
        radius: size / 2,
        backgroundColor: c.pane,
        child: Icon(Icons.notifications_rounded, color: c.muted, size: size * 0.6));
  }

  Widget _message(VC c, Msg m, DateTime t, bool head) {
    final body = <Widget>[
      if (m.img != null)
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: GestureDetector(
            onTap: () => _viewImage(m.img!),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240, maxHeight: 300),
                child: Image.file(File(m.img!),
                    fit: BoxFit.cover,
                    cacheWidth: 600,
                    errorBuilder: (_, __, ___) => Text('Picture not available', style: TextStyle(color: c.faint))),
              ),
            ),
          ),
        ),
      if (m.isNotif && !m.media && (m.title ?? '').isNotEmpty)
        Text(m.title!, style: TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w700)),
      if (m.text.isNotEmpty)
        m.media
            ? Text(m.text, style: TextStyle(color: c.text, fontSize: 15, height: 1.35))
            : m.isNotif
            ? Text(m.text, style: TextStyle(color: c.muted, fontSize: 15, height: 1.35))
            : richText(m.text, c, error: m.error),
      if (m.links.isNotEmpty) linkChips(m.links, c),
      for (final p in m.apps)
        if (_byPkg(p) case final a?)
          AppCard(app: a, onOpen: () => _launch(a), onLongPress: () => showAppMenu(context, a, () => _launch(a))),
      if (m.card != null) _card(c, m),
    ];
    Widget content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: body);

    Widget row;
    if (!head) {
      row = Padding(padding: const EdgeInsets.fromLTRB(68, 4, 16, 2), child: content);
    } else {
      Widget avatar;
      String name;
      if (m.me) {
        avatar = Avatar(name: prefs.name, size: 40, dot: false);
        name = prefs.name;
      } else if (m.isNotif) {
        // A chat app message from someone in your contacts: their photo with the app as a badge
        final person = m.media ? null : People.fromTitle(m.title);
        avatar = person != null
            ? PersonAvatar(name: person.name, person: person, size: 40, badge: _miniAvatar(c, m.pkg, 18))
            : _miniAvatar(c, m.pkg, 40);
        name = m.app ?? m.pkg!;
      } else {
        avatar = Builder(
          builder: (ctx) => GestureDetector(
            onLongPress: () => _quickApps(ctx),
            child: const BotAvatar(size: 40),
          ),
        );
        name = 'Vibe';
      }
      final hasQuote = m.quote != null;
      row = Padding(
        padding: EdgeInsets.fromLTRB(16, hasQuote ? 10 : 12, 16, 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (hasQuote)
            replyStrip(c,
                avatar: _miniAvatar(c, m.quotePkg ?? (m.media ? m.pkg : null), 16),
                name: m.quoteName ?? m.quote!,
                preview: m.quoteName == null ? '' : m.quote!),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            avatar,
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: m.me ? c.muted : c.text, fontWeight: FontWeight.w600, fontSize: 16)),
                  ),
                  if (!m.me && !m.isNotif) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: VC.blurple, borderRadius: BorderRadius.circular(4)),
                      child: const Text('APP',
                          style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 0,
                    child: Text(stamp(t), overflow: TextOverflow.ellipsis, style: TextStyle(color: c.faint, fontSize: 12)),
                  ),
                  if (m.local) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.phone_android_rounded, size: 12, color: c.faint),
                    Text(' On-phone', style: TextStyle(color: c.faint, fontSize: 11)),
                  ],
                ]),
                const SizedBox(height: 2),
                content,
              ]),
            ),
          ]),
        ]),
      );
    }

    // Tap opens a notification; long-press shows options (music: playback controls)
    if (m.isNotif) {
      row = Builder(
        builder: (ctx) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openNotif(m),
          onLongPress: () => m.media ? _mediaPane(ctx, m) : _notifMenu(m),
          child: row,
        ),
      );
    }
    final canReply = !m.me && !m.error && (m.media || m.canReply || !m.isNotif);
    return SwipeReply(
      onReply: canReply ? () => _startReply(m) : null,
      onPassUpdate: _dragUpdate,
      onPassEnd: _dragEnd,
      child: row,
    );
  }

  // ---------- notifications ----------
  void _onNotif(Map n) {
    final pkg = n['pkg']?.toString();
    if (pkg == null || !prefs.showNotifs || prefs.muted.contains(pkg)) return;
    if (n['type'] == 'media') return _onMedia(n, pkg);
    final atBottom = !_scroll.hasClients || _scroll.offset < 80;
    chat.add(Msg(false, (n['text'] ?? '').toString(),
        ts: (n['time'] as num?)?.toInt(),
        pkg: pkg,
        app: n['app']?.toString(),
        title: n['title']?.toString(),
        nkey: n['key']?.toString(),
        canReply: n['canReply'] == true));
    if (atBottom) _toBottom();
  }

  /// Music app "talks": ▶ Playing X, ⏸ Paused X, and song changes quote the previous song.
  void _onMedia(Map n, String pkg) {
    if (!prefs.showMedia) return;
    final title = (n['title'] ?? '').toString();
    final artist = (n['artist'] ?? '').toString();
    final prev = (n['prev'] ?? '').toString();
    final event = n['event'];
    final song = '"$title"${artist.isEmpty ? '' : ' · $artist'}';
    final text = event == 'pause' ? '⏸ Paused $song' : '▶ Playing $song';
    final m = Msg(false, text,
        ts: (n['time'] as num?)?.toInt(),
        pkg: pkg,
        app: n['app']?.toString(),
        media: true,
        quote: event == 'track' && prev.isNotEmpty ? '▶ "$prev"' : null,
        quoteName: event == 'track' && prev.isNotEmpty ? n['app']?.toString() : null,
        quotePkg: event == 'track' && prev.isNotEmpty ? pkg : null);

    // Quick play/pause toggles of the same song just update the last message instead of piling up
    final last = chat.msgs.isNotEmpty ? chat.msgs.last : null;
    final sameSong = last != null &&
        last.media &&
        last.pkg == pkg &&
        last.text.contains('"$title"') &&
        m.ts - last.ts < 2 * 60 * 1000;
    final atBottom = !_scroll.hasClients || _scroll.offset < 80;
    if (sameSong && event != 'track') {
      chat.replaceLast(Msg(false, text,
          ts: m.ts, pkg: pkg, app: m.app, media: true,
          quote: last.quote, quoteName: last.quoteName, quotePkg: last.quotePkg));
    } else {
      chat.add(m);
    }
    if (atBottom) _toBottom();
  }

  /// Long-press a music message: floating ⏮ ⏯ ⏭ pane next to it.
  void _mediaPane(BuildContext msgCtx, Msg m) {
    prefs.heavy();
    _focus.unfocus();
    final c = VC.of(context);
    final box = msgCtx.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset.zero);
    final screenH = MediaQuery.of(context).size.height;
    const paneH = 64.0;
    final top = (pos.dy - paneH - 4 > 90 ? pos.dy - paneH - 4 : pos.dy + box.size.height + 4)
        .clamp(90.0, screenH - paneH - 90);
    final paused = m.text.startsWith('⏸');

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (ctx, _, __) {
        Widget btn(IconData i, String action, {bool big = false}) => InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                prefs.tap();
                Navigator.pop(ctx);
                Native.mediaControl(m.pkg, action);
              },
              child: Container(
                width: big ? 52 : 44,
                height: big ? 52 : 44,
                decoration: big ? const BoxDecoration(color: VC.blurple, shape: BoxShape.circle) : null,
                child: Icon(i, size: big ? 30 : 26, color: big ? Colors.white : c.text),
              ),
            );
        return Stack(children: [
          Positioned(
            left: 68,
            top: top,
            child: Material(
              color: c.card,
              elevation: 8,
              shadowColor: Colors.black54,
              borderRadius: BorderRadius.circular(32),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  btn(Icons.skip_previous_rounded, 'previous'),
                  const SizedBox(width: 4),
                  btn(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, 'toggle', big: true),
                  const SizedBox(width: 4),
                  btn(Icons.skip_next_rounded, 'next'),
                  Container(width: 1, height: 28, margin: const EdgeInsets.symmetric(horizontal: 6), color: c.divider),
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      Navigator.pop(ctx);
                      _notifMenu(m);
                    },
                    child: SizedBox(width: 40, height: 44, child: Icon(Icons.more_horiz_rounded, color: c.muted)),
                  ),
                ]),
              ),
            ),
          ),
        ]);
      },
      transitionBuilder: (ctx, anim, _, child) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          alignment: Alignment.topLeft,
          scale: Tween(begin: 0.9, end: 1.0).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack)),
          child: child,
        ),
      ),
    );
  }

  Future<void> _openNotif(Msg m) async {
    prefs.tap();
    final ok = m.nkey != null && await Native.openNotif(m.nkey!);
    if (!ok) {
      final a = _byPkg(m.pkg!);
      if (a != null) _launch(a);
    }
  }

  void _startReply(Msg m) {
    prefs.tap();
    setState(() => _replyTo = m);
    _focus.requestFocus();
  }

  void _notifMenu(Msg m) {
    prefs.heavy();
    final c = VC.of(context);
    Widget item(IconData icon, String label, VoidCallback onTap, {bool danger = false}) => ListTile(
          leading: Icon(icon, color: danger ? VC.red : c.text),
          title: Text(label, style: TextStyle(color: danger ? VC.red : c.text, fontWeight: FontWeight.w500)),
          onTap: onTap,
        );
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (m.canReply) item(Icons.reply_rounded, 'Reply', () { Navigator.pop(ctx); _startReply(m); }),
          item(Icons.open_in_new_rounded, 'Open', () { Navigator.pop(ctx); _openNotif(m); }),
          item(Icons.copy_rounded, 'Copy text', () {
            Navigator.pop(ctx);
            Clipboard.setData(ClipboardData(text: [m.title, m.text].whereType<String>().join('\n')));
          }),
          item(Icons.notifications_off_outlined, 'Mute ${m.app ?? 'this app'} in Vibe', () {
            Navigator.pop(ctx);
            prefs.toggleMuted(m.pkg!);
            _say('Muted ${m.app ?? m.pkg}. Its notifications won\'t show here. Unmute in launcher settings.');
          }, danger: true),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  /// Send what you typed as a reply: to a chat notification, a music app, or a Vibe message.
  Future<void> _sendReply(Msg to, String text) async {
    setState(() => _replyTo = null);
    final preview = to.isNotif && !to.media && (to.title ?? '').isNotEmpty ? '${to.title}: ${to.text}' : to.text;
    final mine = Msg(true, text,
        quote: preview,
        quoteName: to.isNotif ? (to.media ? to.app : (to.title?.isNotEmpty == true ? to.title : to.app)) : 'Vibe',
        quotePkg: to.isNotif ? to.pkg : 'vibe');
    chat.add(mine);
    _toBottom();

    if (to.media) return _musicReply(to, text);
    if (to.card?['type'] == 'contact') {
      // Replying to a contact card = message that person
      final p = _personOf(to.card!);
      await _doPeople(PeopleCmd('message', name: p.name, text: text), p, '');
      return;
    }
    if (!to.isNotif) {
      // Replying to Vibe: same as a normal message, Gemini sees what you replied to
      final r = Brain.handle(text, _apps);
      if (!r.sure && Gemini.enabled) {
        await _askGemini(text);
      } else {
        await _doLocal(r);
      }
      return;
    }
    final ok = to.nkey != null && await Native.replyNotif(to.nkey!, text);
    if (!ok) {
      _say('I couldn\'t send that. The notification may be gone. Open the chat instead?',
          apps: [if (to.pkg != null && _byPkg(to.pkg!) != null) to.pkg!], error: true);
    }
  }

  /// Reply to a music app: play / pause / next / back, or a song name to search and play there.
  Future<void> _musicReply(Msg to, String text) async {
    final q = Brain.norm(text);
    String? action;
    if (RegExp(r'^(pause|stop|hold)( it| this| song| music)?$').hasMatch(q)) action = 'pause';
    if (RegExp(r'^(play|resume|continue|start|unpause)( it| this| song| music)?$').hasMatch(q)) action = 'play';
    if (RegExp(r'^(next|skip|next song|skip this|skip it|forward)$').hasMatch(q)) action = 'next';
    if (RegExp(r'^(back|previous|prev|last|previous song|go back|before)$').hasMatch(q)) action = 'previous';
    if (action != null) {
      if (!await Native.mediaControl(to.pkg, action)) {
        _say('${to.app ?? 'That app'} isn\'t playing anything I can control right now.', error: true);
      }
      return;
    }
    final song = text.replaceFirst(RegExp(r'^(play|search|find|put on)\s+', caseSensitive: false), '').trim();
    if (!await Native.playMusic(song, pkg: to.pkg)) {
      _say('${to.app ?? 'That app'} can\'t search for songs, so I opened YouTube Music.');
      Native.openUrl('https://music.youtube.com/search?q=${Uri.encodeComponent(song)}');
    }
  }

  /// Newest-first notifications Gemini may see (last 24 h, max 25).
  List<Msg> get _ctxNotifs {
    if (!prefs.aiNotifs) return [];
    final since = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    // OTPs, bank/payment alerts and other private details never go to a cloud AI
    return chat.msgs.reversed
        .where((m) => m.isNotif && !m.media && m.ts > since && !Privacy.msg(m))
        .take(25)
        .toList();
  }

  // ---------- long-press Vibe's avatar: recent apps pane ----------
  void _quickApps(BuildContext avatarCtx) {
    prefs.heavy();
    _focus.unfocus();
    final box = avatarCtx.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset.zero);
    final recent = _recent;
    final c = VC.of(context);
    const per = 4, cell = 56.0;
    final rows = recent.isEmpty ? 1 : (recent.length / per).ceil();
    final paneH = rows * cell + 16;
    final screenH = MediaQuery.of(context).size.height;
    // Show above the avatar if there's room, otherwise below it
    final top = pos.dy - paneH - 8 > 80 ? pos.dy - paneH - 8 : pos.dy + box.size.height + 8;
    final topClamped = top.clamp(80.0, screenH - paneH - 80);

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (ctx, _, __) => Stack(children: [
        Positioned(
          left: 12,
          top: topClamped,
          child: Material(
            color: c.card,
            elevation: 8,
            shadowColor: Colors.black54,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: recent.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Open a few apps first',
                          style: TextStyle(color: c.muted, fontSize: 14)),
                    )
                  : SizedBox(
                      width: per * cell,
                      child: Wrap(children: [
                        for (final a in recent)
                          Tooltip(
                            message: a.label,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                Navigator.pop(ctx);
                                _send('open ${a.label}');
                              },
                              child: SizedBox(
                                width: cell,
                                height: cell,
                                child: Center(child: appIcon(a, 42)),
                              ),
                            ),
                          ),
                      ]),
                    ),
            ),
          ),
        ),
      ]),
      transitionBuilder: (ctx, anim, _, child) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          alignment: Alignment.topLeft,
          scale: Tween(begin: 0.9, end: 1.0)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack)),
          child: child,
        ),
      ),
    );
  }

  // ---------- message box ----------
  Widget _inputBar(VC c) {
    final typing = _input.text.trim().isNotEmpty || _attachImg != null || _attachText != null;
    final to = _replyTo;
    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Row(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: c.input, borderRadius: BorderRadius.circular(28)),
            padding: const EdgeInsets.all(5),
            child: Row(children: [
              Material(
                color: c.pane,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () { prefs.tap(); _plusMenu(); },
                  child: Padding(
                    padding: const EdgeInsets.all(9),
                    child: Icon(Icons.add_rounded, color: c.muted, size: 24),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                  style: TextStyle(color: c.text, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: to == null
                        ? (_attachImg != null || _attachText != null ? 'Ask Vibe about this…' : 'Message Vibe')
                        : to.media
                            ? 'Play, pause, next, back or a song'
                            : 'Reply to ${!to.isNotif ? 'Vibe' : to.title?.isNotEmpty == true ? to.title : to.app}',
                    hintStyle: TextStyle(color: c.faint),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: typing ? VC.blurple : VC.blurple.withValues(alpha: c.dark ? 0.25 : 0.15),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: typing ? () => _send(_input.text) : _voice,
            child: SizedBox(
              width: 54,
              height: 54,
              child: Icon(typing ? Icons.send_rounded : Icons.graphic_eq_rounded,
                  color: typing ? Colors.white : VC.blurple, size: 26),
            ),
          ),
        ),
      ]),
    );
    if (to == null && _attachImg == null && _attachText == null) return bar;
    if (to == null) return Column(mainAxisSize: MainAxisSize.min, children: [_attachBar(c), bar]);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Icon(Icons.reply_rounded, size: 16, color: c.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: 'Replying to ', style: TextStyle(color: c.muted, fontSize: 13)),
                TextSpan(
                    text: !to.isNotif
                        ? 'Vibe'
                        : to.media
                            ? to.app ?? 'music'
                            : [to.title, to.app].where((e) => (e ?? '').isNotEmpty).join(' · '),
                    style: TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w700)),
              ]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            customBorder: const CircleBorder(),
            onTap: () => setState(() => _replyTo = null),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close_rounded, size: 18, color: c.muted),
            ),
          ),
        ]),
      ),
      bar,
    ]);
  }
}

/// All apps, slides in from the left.
class _AppDrawer extends StatefulWidget {
  final List<AppEntry> apps;
  final bool loaded;
  final void Function(AppEntry) onLaunch;
  const _AppDrawer({required this.apps, required this.loaded, required this.onLaunch});
  @override
  State<_AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<_AppDrawer> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final q = _q.trim().toLowerCase();
    final list = widget.apps
        .where((a) => !prefs.hidden.contains(a.pkg) && (q.isEmpty || a.label.toLowerCase().contains(q)))
        .toList();
    int byName(AppEntry a, AppEntry b) => a.label.toLowerCase().compareTo(b.label.toLowerCase());
    if (prefs.sort == SortMode.az || q.isNotEmpty) {
      list.sort(byName);
    } else {
      list.sort((a, b) {
        final d = (prefs.lastUsed[b.pkg] ?? 0).compareTo(prefs.lastUsed[a.pkg] ?? 0);
        return d != 0 ? d : byName(a, b);
      });
    }
    return Material(
      color: c.pane,
      elevation: 16,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(16))),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Row(children: [
              Text('Apps', style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Text('${list.length}', style: TextStyle(color: c.faint, fontSize: 14)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
              height: 40,
              child: TextField(
                onChanged: (v) => setState(() => _q = v),
                onSubmitted: (_) { if (list.isNotEmpty) widget.onLaunch(list.first); },
                textInputAction: TextInputAction.go,
                style: TextStyle(color: c.text, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Find an app',
                  hintStyle: TextStyle(color: c.faint),
                  prefixIcon: Icon(Icons.search_rounded, color: c.faint, size: 20),
                  filled: true,
                  fillColor: c.input,
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
            ),
          ),
          Expanded(
            child: !widget.loaded
                ? const Center(child: CircularProgressIndicator(color: VC.blurple))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: list.length,
                    itemBuilder: (_, i) => Stagger(
                      index: i,
                      dy: 12,
                      child: Pressable(
                        child: AppRow(
                          app: list[i],
                          onTap: () => widget.onLaunch(list[i]),
                          onLongPress: () => showAppMenu(context, list[i], () => widget.onLaunch(list[i])),
                        ),
                      ),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

/// "Vibe is typing…" row with bouncing dots.
class _TypingRowHolder extends StatelessWidget {
  const _TypingRowHolder();
  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(children: [
        const BotAvatar(size: 24),
        const SizedBox(width: 8),
        const TypingDots(),
        const SizedBox(width: 8),
        Text('Vibe is typing…', style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
