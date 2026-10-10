import 'dart:async';
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
import 'player.dart';
import 'imagegen.dart';
import 'search.dart';
import 'privacy.dart';
import 'backup.dart';
import 'day.dart';
import 'dialer.dart';
import 'sched.dart';
import 'profile_sheet.dart';
import 'settings_page.dart';
import 'telegram.dart';
import 'telegram_ui.dart';
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
  bool _drawing = false;
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
    _pack = prefs.iconPack;
    prefs.addListener(_prefsChanged);
    Native.onNotification = _onNotif;
    Native.onShared = _onShared;
    Native.onFired = _onFired;
    appErrors.addListener(_onAppError);
    Native.onPlayer = VibePlayer.i.onEvent;
    Telegram.i.onIncoming = _onTelegram;
    Telegram.i.onDownloaded = (d) {
      if (!mounted) return;
      _say('⬇️ Downloaded **${d['name']}** to Download/Vibe Telegram.', card: {
        'type': 'ask',
        'state': 'ask',
        'uri': d['uri'],
        'mime': d['mime'],
        'buttons': [
          {'label': 'Open', 'do': 'tgfileopen', 'primary': true},
          {'label': 'All downloads', 'do': 'tgdownloads'},
        ],
      });
    };
    if (Telegram.i.configured) Telegram.i.start();
    Native.lastCrash().then((t) {
      if (t == null || t.trim().isEmpty || !mounted) return;
      _say('Vibe closed unexpectedly last time. Long-press this message to copy it and send it for a fix:\n\n$t',
          error: true, local: true);
    });
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
    _input.addListener(_onTyping);
    _refresh();
  }

  String _pack = '';
  void _prefsChanged() {
    if (prefs.iconPack != _pack) {
      _pack = prefs.iconPack;
      _refresh(); // reload icons from the new pack
    }
  }

  @override
  void dispose() {
    appErrors.removeListener(_onAppError);
    prefs.removeListener(_prefsChanged);
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
    _clearLive();
    prefs.tap();
    if (_attachImg != null || _attachText != null) {
      await _sendAttachment(text);
      return;
    }
    if (_replyTo != null) {
      await _sendReply(_replyTo!, text);
      return;
    }
    if (await _keyInChat(text)) return;
    chat.add(Msg(true, text));
    _toBottom();

    // Pictures: "draw …", "create an image of …", "set it as wallpaper"
    final ig = ImageGen.parse(text);
    if (ig != null) {
      await _draw(ig.prompt, wallpaper: ig.wallpaper);
      return;
    }
    if (await _wallpaperCommand(text)) return;
    final mem = memory.handle(text);
    if (mem != null) {
      await Future.delayed(const Duration(milliseconds: 250));
      _say(mem);
      return;
    }
    if (await _musicCommands(text)) return;
    if (await _dialerCommands(text)) return;
    if (await _telegramCommands(text)) return;
    if (await _selfCommands(text)) return;
    if (await _appCommands(text)) return;
    if (await _dayCommands(text)) return;
    if (await _schedule(text)) return;
    final cal = CalCmd.parse(text);
    if (cal != null) {
      await _calendar(cal);
      return;
    }
    final pc = People.parse(text);
    if (pc != null && await _people(pc)) return;
    if (pc != null && pc.action != 'calls' && !Gemini.enabled && _nano != 'available') {
      await Future.delayed(const Duration(milliseconds: 250));
      _say('I couldn\'t find "${pc.name}" in your contacts. Try their name as it\'s saved, or type the number, like "call 98765 43210".');
      return;
    }
    if (isMissCmd(text) && await _whatDidIMiss()) return;
    final r = Brain.handle(text, _apps);
    if (!r.sure && (Gemini.enabled || _nano == 'available')) {
      await _askGemini(text);
    } else {
      await Future.delayed(const Duration(milliseconds: 250));
      await _doLocal(r);
    }
  }

  void _onAppError() {
    final e = appErrors.value;
    if (e == null || !mounted) return;
    appErrors.value = null;
    Future.microtask(() {
      if (mounted) _say('Something went wrong (Vibe kept running). Long-press to copy it for a fix:\n\n$e', error: true, local: true);
    });
  }

  void _say(String text,
      {List<String> apps = const [],
      List<Map> links = const [],
      bool error = false,
      Map? card,
      bool local = false,
      String? img,
      String? ai}) {
    chat.add(Msg(false, text,
        apps: apps, links: links, error: error, card: card, local: local, img: img, ai: ai, thread: _curThread));
    _toBottom();
  }

  Future<void> _pause() => Future.delayed(const Duration(milliseconds: 350));

  /// Waits until an app's "Opening…" message has fully slid into the timeline, then the app can open.
  Future<void> _shown() async {
    _toBottom();
    await WidgetsBinding.instance.endOfFrame;
    await Future.delayed(const Duration(milliseconds: 560));
  }

  Future<void> _doLocal(Reply r) async {
    if (r.act == Act.clear) {
      chat.clear();
      _say('Chat cleared.');
      return;
    }
    // Opening an app or Settings: the app itself answers
    if (r.act == Act.open && r.app != null) {
      _appSays(r.app!.pkg, r.app!.label, 'Opening…');
      await _shown();
      _launch(r.app!);
      return;
    }
    if (r.act == Act.phoneSettings) {
      _appSays(_settingsPkg, 'Settings', 'Opening Settings…', action: {'settings': 'android.settings.SETTINGS'});
      await _shown();
      Native.openSettings();
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
        if (VibePlayer.i.active) {
          await VibePlayer.i.cmd(r.media);
        } else if (!await Native.mediaControl(null, r.media)) {
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

  double get _panelW => MediaQuery.of(context).size.width;

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
  // ---------- Conversation threads ----------
  String? _curThread; // the thread being answered right now

  /// Continue the latest conversation if it was recent, otherwise start a new one.
  String _threadForNew() {
    for (final m in chat.msgs.reversed) {
      if (m.thread != null) {
        if (DateTime.now().millisecondsSinceEpoch - m.ts < 15 * 60 * 1000) return m.thread!;
        break;
      }
    }
    return 't${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Puts your newest message into the thread.
  void _tagLastMine(String t) {
    for (var i = chat.msgs.length - 1; i >= 0; i--) {
      final m = chat.msgs[i];
      if (m.me) {
        if (m.thread != t) chat.replace(m, m.inThread(t));
        return;
      }
    }
  }

  Future<void> _askGemini(String question, {String? imagePath, List<Msg>? history, String? thread}) async {
    final t = thread ?? _threadForNew();
    if (history == null) _tagLastMine(t);
    final convo = history ?? chat.msgs.where((m) => m.thread == t).toList();
    _curThread = t;
    try {
      await _askAi(question, convo, imagePath: imagePath, queued: history != null);
    } finally {
      _curThread = null;
    }
  }

  Future<void> _askAi(String question, List<Msg> convo, {String? imagePath, bool queued = false}) async {
    // No cloud key, or no internet: the on-phone AI answers if it can
    if (!queued && (!_netOk || !Gemini.enabled) && _nano == 'available') {
      if (await _askNano(question, imagePath: imagePath, convo: convo)) return;
    }
    if (!_netOk && !queued) {
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
      final res = await Gemini.ask(convo, _apps, _askedNotifs, imagePath: imagePath);
      if (!mounted) return;
      if (res.error != null) {
        _say(res.error!, error: true);
        return;
      }
      final tag = Gemini.label(res.via);
      if (res.calls.isEmpty) {
        _say(res.text.isEmpty ? '🤔' : res.text, ai: tag);
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
        if (preface.isNotEmpty && !preface.toLowerCase().startsWith('opening')) _say(preface);
        _appSays(app.pkg, app.label, 'Opening…');
        await _shown();
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
        if (preface.isNotEmpty) _say(preface);
        await _playSong(str('query'));
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
      case 'vibe_setting':
        if (preface.isNotEmpty) _say(preface);
        await _applySetting(str('setting'));
      case 'vibe_status':
        if (preface.isNotEmpty) _say(preface);
        final what = str('what');
        if (what == 'offline_model') {
          await _offlineModel();
        } else {
          await _checkStatus(withModel: what != 'ai_keys');
        }
      case 'download_offline_model':
        if (preface.isNotEmpty) _say(preface);
        await _offlineModel(wantDownload: true);
      case 'media_control':
        final action = str('action');
        if (preface.isNotEmpty) _say(preface);
        if (VibePlayer.i.active) {
          await VibePlayer.i.cmd(action.isEmpty ? 'toggle' : action);
        } else if (!await Native.mediaControl(null, action.isEmpty ? 'toggle' : action)) {
          _say('Nothing is playing right now, or notification access is off.');
        }
      case 'call_person':
        if (!await _people(PeopleCmd('call', name: str('name')), preface: preface)) {
          _say('I couldn\'t find "${str('name')}" in your contacts.');
        }
      case 'message_person' when str('via') == 'telegram':
        if (preface.isNotEmpty) _say(preface);
        await _telegramTo(str('name'), str('text'));
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
      case 'generate_image':
        if (preface.isNotEmpty) _say(preface);
        await _draw(str('prompt'));
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
    // A phone number instead of a name: "call 98765 43210", "message +91 98765 43210 hi".
    // Works even without contacts permission.
    final number = pc.action == 'calls' ? null : _numberIn(pc.name);
    if (number != null) {
      if (People.all.isEmpty && People.ready) await People.load();
      await _doPeople(pc, _personForNumber(number), preface);
      return true;
    }
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

  /// The phone number in [s] if that's all it is (digits, spaces, dashes, brackets, a leading +).
  String? _numberIn(String s) {
    final t = s.trim();
    if (!RegExp(r'^\+?[\d\s\-().]{3,}$').hasMatch(t)) return null;
    final digits = t.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length < 3) return null;
    return t.startsWith('+') ? '+$digits' : digits;
  }

  /// A saved contact with this number, or an unsaved "person" that is just the number.
  Person _personForNumber(String number) {
    final d = number.replaceAll(RegExp(r'\D'), '');
    if (d.length >= 7) {
      for (final p in People.all) {
        final pd = p.number.replaceAll(RegExp(r'\D'), '');
        if (pd.length >= 7 && pd.substring(pd.length - 7) == d.substring(d.length - 7)) return p;
      }
    }
    return Person('', number, number, true, false, false, false);
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

    Widget actionPill(String label, VoidCallback? onTap, {bool primary = false}) => Padding(
          padding: const EdgeInsets.only(right: 8, top: 8),
          child: Material(
            color: primary ? VC.blurple : c.input,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap == null
                  ? null
                  : () {
                      prefs.tap();
                      onTap();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Text(label,
                    style: TextStyle(
                        color: primary ? Colors.white : c.text, fontWeight: FontWeight.w600, fontSize: 14)),
              ),
            ),
          ),
        );

    switch (card['type']) {
      // Vibe checking itself: keys, offline AI, theme
      case 'status':
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: box(),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Column(children: [
            for (final r in List<Map>.from(card['rows'] ?? const []))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: r['ok'] == true ? VC.green : r['ok'] == false ? VC.red : c.faint,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('${r['label']}',
                        style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 14.5)),
                  ),
                  Flexible(
                    child: Text('${r['value']}',
                        textAlign: TextAlign.right,
                        style: TextStyle(color: r['ok'] == false ? VC.red : c.muted, fontSize: 13)),
                  ),
                ]),
              ),
          ]),
        );
      case 'ask':
        final done = card['state'] != 'ask';
        final preview = card['preview']?.toString();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (preview != null)
            Container(
              margin: const EdgeInsets.only(top: 6),
              constraints: const BoxConstraints(maxWidth: 360),
              decoration: box(),
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (card['to'] != null)
                  Text('To ${card['to']}', style: TextStyle(color: c.faint, fontSize: 12, fontWeight: FontWeight.w700)),
                Text(preview, style: TextStyle(color: c.text, fontSize: 15)),
                if (card['state'] == 'sent')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('✓ Sent', style: TextStyle(color: VC.green, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
              ]),
            ),
          Wrap(children: [
          for (final b in List<Map>.from(card['buttons'] ?? const []))
            actionPill('${b['label']}', done ? null : () => _onAsk(m, '${b['do']}'), primary: b['primary'] == true),
          ]),
        ]);
      case 'player':
        return PlayerCard(card: card);
      case 'tgfile':
        return TgFileTile(file: TgFile.fromCard(card), from: '${card['from'] ?? ''}');
      case 'models':
        final picked = card['picked']?.toString();
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: box(),
          child: Column(children: [
            for (final it in List<Map>.from(card['items'] ?? const []))
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: picked != null ? null : () => _pickModel(m, it),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(color: VC.blurple, borderRadius: BorderRadius.circular(10)),
                      child: Icon(
                          switch (card['kind']) {
                            'iconpack' => Icons.palette_rounded,
                            'unhide' => Icons.visibility_rounded,
                            'unmute' => Icons.notifications_active_rounded,
                            'gemini' || 'groq' => Icons.auto_awesome_rounded,
                            _ => Icons.phone_android_rounded,
                          },
                          color: Colors.white,
                          size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${it['name']}',
                            style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 15)),
                        Text('${it['sub']}', style: TextStyle(color: c.faint, fontSize: 12)),
                      ]),
                    ),
                    Icon(picked == it['id'] ? Icons.check_circle_rounded : card['kind'] == null ? Icons.download_rounded : Icons.chevron_right_rounded,
                        color: picked == it['id'] ? VC.green : c.muted),
                  ]),
                ),
              ),
          ]),
        );
      case 'progress':
        final done = (card['done'] as num?)?.toDouble() ?? 0;
        final total = (card['total'] as num?)?.toDouble() ?? 0;
        final st = card['state'];
        final frac = st == 'done' ? 1.0 : (total > 0 ? (done / total).clamp(0.0, 1.0) : null);
        String mb(double b) => b >= 1e9 ? '${(b / 1e9).toStringAsFixed(2)} GB' : '${(b / 1e6).toStringAsFixed(0)} MB';
        final line = st == 'done'
            ? 'Installed'
            : st == 'failed'
                ? 'Download stopped'
                : total > 0
                    ? '${mb(done)} of ${mb(total)} · ${((frac ?? 0) * 100).toStringAsFixed(0)}%'
                    : done > 0
                        ? '${mb(done)} downloaded'
                        : 'Starting…';
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: box(),
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(st == 'done' ? Icons.check_circle_rounded : st == 'failed' ? Icons.error_rounded : Icons.downloading_rounded,
                  size: 18, color: st == 'done' ? VC.green : st == 'failed' ? VC.red : VC.blurple),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${card['title']}', style: TextStyle(color: c.text, fontWeight: FontWeight.w700)),
              ),
              Text(line, style: TextStyle(color: c.muted, fontSize: 12)),
            ]),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: frac ?? 0),
                duration: const Duration(milliseconds: 400),
                builder: (_, v, __) => LinearProgressIndicator(
                  value: frac == null ? null : v,
                  minHeight: 6,
                  backgroundColor: c.input,
                  color: st == 'failed' ? VC.red : st == 'done' ? VC.green : VC.blurple,
                ),
              ),
            ),
          ]),
        );
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
            tile(Icons.manage_search_rounded, const Color(0xFFF26522), 'Search', () {
              Navigator.pop(ctx);
              _openSearch();
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
  String _nanoPrompt(String question, {String extra = '', List<Msg>? convo}) {
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
    final talk = (convo ?? chat.msgs)
        .where((m) => !m.isNotif && !m.talk && !m.error && m.text.trim().isNotEmpty && m.card == null)
        .toList();
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
  Future<bool> _askNano(String question, {String? imagePath, String extra = '', List<Msg>? convo}) async {
    setState(() => _thinking = true);
    _toBottom();
    final text = await Native.nanoAsk(_nanoPrompt(question, extra: extra, convo: convo), image: imagePath);
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
  void _openSearch([String q = '']) {
    _focus.unfocus();
    _closeDrawer();
    SearchPage.open(context,
        apps: _apps,
        initial: q,
        onLaunch: _launch,
        onMailSettings: () => SettingsPage.openPage(context, 'SEARCH'));
  }

  Future<bool> _dayCommands(String text) async {
    // "find ravi's pdf", "search passport": global search on the phone (web searches go to Gemini)
    final find = RegExp(r'^(?:find|search|look for|look up)(?:\s+for)?\s*(.*)$', caseSensitive: false).firstMatch(text.trim());
    if (find != null && !RegExp(r'\b(google|web|online|internet|news|weather|price|score|wikipedia)\b', caseSensitive: false).hasMatch(text)) {
      _openSearch(find.group(1)!.trim());
      return true;
    }
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

  // ---------- Music: Vibe's own player first, then streaming apps silently ----------
  /// "play blinding lights", "play songs by the weeknd", "play my downloads", "play X on spotify"
  Future<bool> _musicCommands(String text) async {
    final t = text.trim();
    final low = Brain.norm(t);
    final m = RegExp(r'^(?:please )?(?:play|put on|listen to|start playing)\s+(.+)$').firstMatch(low);
    if (m == null) return false;
    var q = m.group(1)!.trim();
    // "play", "play next", "play music" etc. are controls: leave them to the usual handling
    if (RegExp(r'^(it|this|that|the music|music|the song|song|next|previous|prev|again|on)$').hasMatch(q)) return false;
    // "… on spotify" / "… in yt music": that app
    String? pkg;
    final on = RegExp(r'^(.+?)\s+(?:on|in|using|with|from)\s+(.+)$').firstMatch(q);
    if (on != null) {
      final app = Brain.match(Brain.norm(on.group(2)!), _apps);
      if (app.isNotEmpty && app.first.score >= 70) {
        pkg = app.first.app.pkg;
        q = on.group(1)!.trim();
      }
    }
    // A game / video / app called this? "play subway surfers" should open the app, not music
    if (pkg == null) {
      final app = Brain.match(Brain.norm(q), _apps);
      if (app.isNotEmpty && app.first.score >= 90) return false;
    }
    await _playSong(q, pkg: pkg);
    return true;
  }

  Future<void> _playSong(String query, {String? pkg}) async {
    var q = query.trim().replaceAll(RegExp(r'\s+(song|track|music)$'), '');
    if (q.isEmpty) return;
    // 1) Songs on this phone → Vibe plays them itself (unless you named a streaming app)
    if (pkg == null) {
      final perms = await Native.requestAudio();
      if (perms['audio'] == true) {
        List<Map> songs;
        String title;
        final by = RegExp(r'^(?:songs?|music|something) (?:by|from) (.+)$').firstMatch(q);
        if (RegExp(r'^(my )?(downloads|downloaded songs|downloaded music|telegram (songs|music|downloads))$').hasMatch(q)) {
          songs = await Native.searchSongs('', by: 'downloads');
          title = 'your downloads';
        } else if (RegExp(r'^(my )?(music|songs|library|playlist|some music|anything|all songs)$').hasMatch(q)) {
          songs = (await Native.searchSongs('', by: 'all'))..shuffle();
          title = 'your music';
        } else if (by != null) {
          songs = (await Native.searchSongs(by.group(1)!, by: 'artist'))..shuffle();
          title = 'songs by ${by.group(1)}';
        } else {
          songs = await Native.searchSongs(q);
          // Best match first: exact title, then title starting with it, then the rest
          final n = Brain.norm(q);
          int rank(Map s) {
            final ti = Brain.norm('${s['title']}');
            if (ti == n) return 0;
            if (ti.startsWith(n)) return 1;
            if (ti.contains(n)) return 2;
            return 3;
          }
          songs.sort((a, b) => rank(a).compareTo(rank(b)));
          title = songs.isEmpty ? q : '${songs.first['title']}';
        }
        if (songs.isNotEmpty) {
          final list = songs.take(100).toList();
          await VibePlayer.i.play(list);
          _say('▶ Playing $title', card: {'type': 'player', 'songs': list, 'index': 0});
          return;
        }
      }
    }
    // 2) Not on the phone: ask your music app to play it in the background
    if (VibePlayer.i.active) VibePlayer.i.cmd('stop'); // one player at a time
    setState(() => _thinking = true);
    final sent = DateTime.now().millisecondsSinceEpoch;
    final r = await Native.playSilently(q, pkg: pkg);
    if (mounted) setState(() => _thinking = false);
    if (r != null) {
      final app = '${r['label']}';
      final target = '${r['package']}';
      _appSays(target, app, 'Playing "$q"…');
      // If the app didn't actually start playing, open it the usual way
      Future.delayed(const Duration(seconds: 7), () async {
        if (!mounted) return;
        final started = chat.msgs.reversed.take(15).any((x) => x.media && x.pkg == target && x.ts >= sent - 1000);
        if (!started) {
          _say('$app didn\'t start in the background, so I\'m opening it.');
          await Native.playMusic(q, pkg: target);
        }
      });
      return;
    }
    // 3) Last resort: open a music app by search
    _say('Playing $q…');
    await _pause();
    if (!await Native.playMusic(q, pkg: pkg)) {
      _say('Your music app can\'t play by search, so I opened it on YouTube Music instead.');
      Native.openUrl('https://music.youtube.com/search?q=${Uri.encodeComponent(q)}');
    }
  }

  // ---------- Dial pad ----------
  void _openDialer([String number = '']) {
    _focus.unfocus();
    navKey.currentState?.push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, __, ___) => DialerPage(initial: number),
      transitionsBuilder: (_, a, __, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: FadeTransition(opacity: a, child: child),
      ),
    ));
  }

  /// "dialer", "keypad", "dial 98765 43210", or just a phone number on its own.
  Future<bool> _dialerCommands(String text) async {
    final t = text.trim();
    final low = Brain.norm(t);
    if (RegExp(r'^(open |show )?(the )?(dialer|dial ?pad|key ?pad|phone ?pad|dial|numpad|number pad)$').hasMatch(low)) {
      _openDialer();
      return true;
    }
    final dial = RegExp(r'^dial\s+([+\d][\d\s\-()*#+]*)$', caseSensitive: false).firstMatch(t);
    if (dial != null) {
      _openDialer(dial.group(1)!.replaceAll(RegExp(r'[\s\-()]'), ''));
      return true;
    }
    // A bare number: offer call / message / save
    if (RegExp(r'^[+]?[\d\s\-()]{7,}$').hasMatch(t) && t.replaceAll(RegExp(r'\D'), '').length >= 7) {
      final n = (t.startsWith('+') ? '+' : '') + t.replaceAll(RegExp(r'\D'), '');
      final p = _personForNumber(n);
      await Future.delayed(const Duration(milliseconds: 200));
      _say(p.id.isEmpty ? n : '${p.name} · $n', card: {
        'type': 'ask',
        'state': 'ask',
        'number': n,
        'buttons': [
          {'label': 'Call', 'do': 'numcall', 'primary': true},
          {'label': 'Message', 'do': 'nummsg'},
          if (p.id.isEmpty) {'label': 'Save contact', 'do': 'numsave'},
          {'label': 'Dial pad', 'do': 'numpad'},
        ],
      });
      return true;
    }
    // USSD / phone codes typed in chat: *123#, *#06#
    if (RegExp(r'^\*[\d*#]+#$').hasMatch(t)) {
      t.startsWith('*#') ? await Native.dialPad(t) : await Native.call(t);
      return true;
    }
    return false;
  }

  // ---------- Telegram inside Vibe ----------
  /// A Telegram message arrives: it shows up like any app message, but replies go straight to Telegram.
  void _onTelegram(Map tm) {
    final tg = Telegram.i;
    final chatId = Telegram.chatOf(tm);
    final chatRow = tg.chats[chatId];
    final sender = tg.senderName(tm);
    final title = chatRow == null || Telegram.isPrivate(chatRow) ? sender : '$sender · ${tg.chatTitle(chatId)}';
    final pkg = Telegram.appPackages.firstWhere((p) => _byPkg(p) != null, orElse: () => 'org.telegram.messenger');
    final atBottom = !_scroll.hasClients || _scroll.offset < 80;
    final file = TgFile.of(tm);
    final caption = file == null ? Telegram.textOf(tm) : (((tm['content'] as Map?)?['caption'] as Map?)?['text'] ?? '').toString();
    final hasButtons = (tm['reply_markup'] as Map?)?['@type'] == 'replyMarkupInlineKeyboard';
    chat.add(Msg(false, caption.isEmpty && file == null ? Telegram.textOf(tm) : caption,
        ts: (((tm['date'] as num?) ?? 0).toInt() * 1000),
        pkg: pkg,
        app: 'Telegram',
        title: title,
        nkey: 'tg:$chatId:${Telegram.idOf(tm)}',
        canReply: true,
        card: file != null
            ? (file.toCard()..['from'] = tg.chatTitle(chatId))
            : hasButtons
                ? {'type': 'ask', 'state': 'ask', 'chat': chatId, 'buttons': [
                    {'label': 'Open to choose', 'do': 'tgopen', 'primary': true}
                  ]}
                : null));
    if (atBottom) _toBottom();
  }

  void _openTelegramChat(int chatId, {String start = ''}) {
    _focus.unfocus();
    navKey.currentState?.push(MaterialPageRoute(builder: (_) => TelegramChatPage(chatId: chatId, startParam: start)));
  }

  Future<void> _openTelegramLogin() async {
    _focus.unfocus();
    final ok = await navKey.currentState?.push<bool>(MaterialPageRoute(builder: (_) => const TelegramLoginPage()));
    if (ok == true) _say('✅ Telegram connected. Your chats now arrive here, and you can reply by swiping.');
  }

  void _openTelegramChats({int tab = 0}) {
    _focus.unfocus();
    navKey.currentState?.push(MaterialPageRoute(builder: (_) => TelegramChatsPage(tab: tab)));
  }

  Future<void> _tgJoinFromCard(Msg m) async {
    final card = m.card!;
    _setCard(m, Map.from(card)..['state'] = 'joined');
    final err = card['invite'] != null
        ? await Telegram.i.joinInvite('${card['invite']}')
        : await Telegram.i.join((card['chat'] as num).toInt());
    if (err != null) {
      _setCard(m, Map.from(card)..['state'] = 'ask');
      _say('Couldn\'t join: $err', error: true);
      return;
    }
    _say('✅ Joined **${card['to']}**. Say "telegram downloads" anytime, or open it to browse files.', card: {
      'type': 'ask',
      'state': 'ask',
      'chat': card['chat'],
      'buttons': [
        {'label': 'Open channel', 'do': 'tgopen', 'primary': true},
      ],
    });
  }

  void _tgChatCard(Map c, {String start = ''}) {
    final id = Telegram.idOf(c);
    if (Telegram.i.isBot(c)) {
      _say('🤖 **${c['title']}** is a bot.', card: {
        'type': 'ask',
        'state': 'ask',
        'chat': id,
        'start': start,
        'buttons': [
          {'label': 'Start bot', 'do': 'tgstart', 'primary': true},
        ],
      });
      return;
    }
    final member = Telegram.i.isMember(c);
    _say('📢 **${c['title']}**', card: {
      'type': 'ask',
      'state': 'ask',
      'to': c['title'],
      'chat': id,
      'buttons': [
        if (!member) {'label': 'Join', 'do': 'tgjoin', 'primary': true},
        {'label': member ? 'Open' : 'Preview', 'do': 'tgopen', 'primary': member},
      ],
    });
  }

  /// A t.me link (or @name) pasted into Vibe: show what it is, with Join / Start / Download.
  Future<bool> _telegramLink(String text) async {
    final link = Telegram.linkIn(text);
    if (link == null) return false;
    if (!Telegram.i.ready) {
      if (!Telegram.i.configured) return false;
      _say('Telegram is still connecting. Try the link again in a moment.', error: true);
      return true;
    }
    setState(() => _thinking = true);
    Map? r;
    try {
      r = await Telegram.i.resolveLink(link);
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
    if (r == null || r['kind'] == 'error') {
      _say('${r?['error'] ?? 'That Telegram link didn\'t work.'}', error: true);
      return true;
    }
    switch (r['kind']) {
      case 'invite':
        final info = r['info'] as Map;
        final cid = (info['chat_id'] as num?)?.toInt() ?? 0;
        final members = (info['member_count'] as num?)?.toInt() ?? 0;
        _say('**${info['title']}**${members > 0 ? ' · $members members' : ''}', card: {
          'type': 'ask',
          'state': 'ask',
          'to': info['title'],
          'chat': cid,
          if (cid == 0) 'invite': r['link'],
          'preview': '${info['description'] ?? ''}'.trim().isEmpty ? 'Private channel or group' : '${info['description']}',
          'buttons': [
            if (cid == 0) {'label': 'Join', 'do': 'tgjoin', 'primary': true} else {'label': 'Open', 'do': 'tgopen', 'primary': true},
          ],
        });
      case 'post':
        final msg = r['message'] as Map;
        final file = TgFile.of(msg);
        final from = Telegram.i.chatTitle(Telegram.chatOf(msg));
        _say(file == null ? 'Post from **$from**:\n${Telegram.textOf(msg)}' : 'File from **$from**:',
            card: file == null
                ? {'type': 'ask', 'state': 'ask', 'chat': Telegram.chatOf(msg), 'buttons': [
                    {'label': 'Open channel', 'do': 'tgopen', 'primary': true}
                  ]}
                : (file.toCard()..['from'] = from));
      case 'chat':
        _tgChatCard(r['chat'] as Map, start: '${r['start'] ?? ''}');
    }
    return true;
  }

  /// "telegram chats", "connect telegram", "telegram Ravi I'm late", "message Ravi on telegram hi"
  Future<bool> _telegramCommands(String text) async {
    if (Telegram.linkIn(text) != null && await _telegramLink(text)) return true;
    final low = Brain.norm(text);
    if (Telegram.i.configured) {
      if (RegExp(r'^(my |show |open )*(telegram )?downloads?$|^telegram (files|downloads)$').hasMatch(low) && low.contains('download') ||
          low == 'telegram downloads' || low == 'telegram files') {
        _openTelegramChats(tab: 2);
        return true;
      }
      if (RegExp(r'^(my |show |open )*(telegram )?bots$').hasMatch(low)) {
        _openTelegramChats(tab: 1);
        return true;
      }
      if (RegExp(r'^(my |show |open )*(telegram )?channels$').hasMatch(low)) {
        _openTelegramChats(tab: 0);
        return true;
      }
      final join = RegExp(r'^join\s+@?([A-Za-z][\w]{3,})(?:\s+(?:on\s+)?telegram)?$', caseSensitive: false).firstMatch(text.trim());
      if (join != null) return _telegramLink('t.me/${join.group(1)}');
      final find = RegExp(r'^(?:search|find)\s+(?:telegram|tg)\s+(?:for\s+)?(.+)$|^(?:search|find)\s+(.+?)\s+on\s+telegram$',
              caseSensitive: false)
          .firstMatch(text.trim());
      if (find != null && Telegram.i.ready) {
        final q = (find.group(1) ?? find.group(2) ?? '').trim();
        setState(() => _thinking = true);
        final found = await Telegram.i.searchPublic(q);
        if (mounted) setState(() => _thinking = false);
        if (found.isEmpty) {
          _say('Nothing on Telegram called "$q".');
        } else {
          for (final c in found.take(4)) {
            _tgChatCard(c);
          }
        }
        return true;
      }
    }
    if (!low.contains('telegram') && !low.startsWith('tg ')) return false;
    if (RegExp(r'^(connect|log ?in to|login to|sign in to|set ?up|add) telegram$|^telegram (login|log in|connect|setup|set up)$').hasMatch(low)) {
      await _openTelegramLogin();
      return true;
    }
    if (RegExp(r'^(log ?out of|logout of|disconnect|sign out of) telegram$|^telegram (log ?out|logout|disconnect)$').hasMatch(low)) {
      await Telegram.i.logOut();
      _say('Logged out of Telegram in Vibe. The Telegram app itself is unchanged.');
      return true;
    }
    if (RegExp(r'^(open |show |my )*telegram( chats| messages)?$|^tg$').hasMatch(low)) {
      if (!Telegram.i.configured) {
        // Not set up in Vibe: open the Telegram app as before, and offer to connect
        final a = Telegram.appPackages.map(_byPkg).whereType<AppEntry>().firstOrNull;
        if (a != null && !low.contains('chats')) return false;
        _say('Telegram isn\'t connected to Vibe yet.', card: {
          'type': 'ask',
          'state': 'ask',
          'buttons': [
            {'label': 'Connect Telegram', 'do': 'tglogin', 'primary': true},
          ],
        });
        return true;
      }
      _openTelegramChats();
      return true;
    }
    // Sending
    final raw = text.trim();
    final a = RegExp(r'^(?:telegram|tg)\s+(.+)$', caseSensitive: false).firstMatch(raw);
    final b = RegExp(r'^(?:message|msg|text|send(?: a message to)?)\s+(.+?)\s+(?:on|via|in|through)\s+telegram\b[\s:,-]*(.*)$',
            caseSensitive: false)
        .firstMatch(raw);
    if (b != null) {
      await _telegramTo(b.group(1)!, b.group(2) ?? '');
      return true;
    }
    if (a != null) {
      await _telegramTo(a.group(1)!, '', splitName: true);
      return true;
    }
    return false;
  }

  /// Finds the chat and either opens it (no text) or asks before sending.
  Future<void> _telegramTo(String who, String text, {bool splitName = false}) async {
    if (!Telegram.i.configured) {
      _say('Connect Telegram to Vibe first.', card: {
        'type': 'ask',
        'state': 'ask',
        'buttons': [
          {'label': 'Connect Telegram', 'do': 'tglogin', 'primary': true},
        ],
      });
      return;
    }
    if (!Telegram.i.ready) {
      await Telegram.i.start();
      _say('Telegram is still connecting. Try again in a moment.', error: true);
      return;
    }
    setState(() => _thinking = true);
    Map? chatRow;
    var msg = text.trim();
    try {
      final number = _numberIn(who.split(RegExp(r'\s+')).first) != null && !splitName ? _numberIn(who) : null;
      if (splitName) {
        // "telegram Ravi Kumar I'm late": the longest run of first words that's a chat name
        final words = who.trim().split(RegExp(r'\s+'));
        final phone = RegExp(r'^(\+?\d[\d\s\-()]{4,}\d)(?:\s+(.*))?$').firstMatch(who.trim());
        if (phone != null) {
          chatRow = await Telegram.i.chatForPhone(phone.group(1)!);
          msg = phone.group(2) ?? '';
        } else {
          for (var k = words.length > 4 ? 4 : words.length; k >= 1 && chatRow == null; k--) {
            final name = words.take(k).join(' ');
            final local = _localTgChat(name);
            if (local != null) {
              chatRow = local;
              msg = words.skip(k).join(' ');
            }
          }
          if (chatRow == null) {
            final found = await Telegram.i.findChats(words.first);
            if (found.isNotEmpty) {
              chatRow = found.first;
              msg = words.skip(1).join(' ');
            }
          }
        }
      } else if (number != null) {
        chatRow = await Telegram.i.chatForPhone(number);
      } else {
        chatRow = _localTgChat(who);
        if (chatRow == null) {
          final found = await Telegram.i.findChats(who);
          if (found.isNotEmpty) chatRow = found.first;
        }
      }
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
    if (chatRow == null) {
      _say('I couldn\'t find "$who" on Telegram. Try their name as it shows in Telegram, their @username, or their number '
          '(numbers only work if they allow it in Telegram privacy).');
      return;
    }
    final id = Telegram.idOf(chatRow);
    final title = '${chatRow['title']}';
    msg = msg.replaceFirst(RegExp(r'^(that|saying|to say|:|-)\s*', caseSensitive: false), '').trim();
    if (msg.isEmpty) {
      _say('Opening $title on Telegram…');
      await _pause();
      _openTelegramChat(id);
      return;
    }
    _say('Send this on Telegram?', card: {
      'type': 'ask',
      'state': 'ask',
      'to': title,
      'chat': id,
      'preview': msg,
      'buttons': [
        {'label': 'Send', 'do': 'tgsend', 'primary': true},
        {'label': 'Open chat', 'do': 'tgopen'},
      ],
    });
  }

  Map? _localTgChat(String name) {
    final q = Brain.norm(name);
    if (q.isEmpty) return null;
    Map? best;
    var bestScore = 0;
    for (final c in Telegram.i.chats.values) {
      final t = Brain.norm('${c['title']}');
      final sc = t == q ? 100 : t.startsWith('$q ') ? 90 : t.split(' ').contains(q) ? 80 : 0;
      if (sc > bestScore) {
        bestScore = sc;
        best = c;
      }
    }
    return best;
  }

  Future<void> _tgSendFromCard(Msg m) async {
    final card = m.card!;
    final r = await Telegram.i.sendText((card['chat'] as num).toInt(), '${card['preview']}');
    if (Telegram.isError(r)) {
      _setCard(m, Map.from(card)..['state'] = 'ask');
      _say('Telegram didn\'t send it: ${r['message']}', error: true);
    } else {
      _setCard(m, Map.from(card)..['state'] = 'sent');
    }
  }

  // ---------- Vibe's own settings by chat ----------
  /// "dark mode", "follow system", "check my api keys", "is the offline AI downloaded?", "download offline model"
  Future<bool> _selfCommands(String text) async {
    final low = Brain.norm(text);
    bool has(String re) => RegExp(re).hasMatch(low);
    if (has(r'^(what|which) (version|app version)|^(vibe |app )?version$|^what version')) {
      await _reply('You\'re on Vibe Launcher $vibeVersion.');
      return true;
    }
    if (RegExp(r'^(what|why|how|does|do|can|should) ').hasMatch(low) && !low.contains('offline') && !low.contains('key')) {
      return false;
    }
    if (await _moreSettings(low, text)) return true;
    // Theme
    if (has(r'\b(follow (the )?system|system (theme|mode|default)|auto (theme|dark mode)|same as (the )?(phone|system))\b')) {
      await _applySetting('follow_system_theme');
      return true;
    }
    if (has(r'\bdark (mode|theme)\b') && !has(r'\b(off|disable|turn off|no)\b')) {
      await _applySetting('dark_mode');
      return true;
    }
    if (has(r'\b(light|white) (mode|theme)\b') || has(r'\bdark (mode|theme) (off|disable)\b') ||
        has(r'\b(turn off|disable) dark (mode|theme)\b')) {
      await _applySetting('light_mode');
      return true;
    }
    // Offline (on-phone) AI model
    final model = has(r'\b(offline|on ?phone|on device|local|nano)\b') && has(r'\b(ai|model|llm|nano)\b');
    if (model) {
      final want = has(r'\b(download|install|get|setup|set up)\b') && !has(r'\b(is|are|did|has|have|downloaded|installed)\b');
      await _offlineModel(wantDownload: want);
      return true;
    }
    // AI keys
    if (has(r'\b(api )?keys?\b') && has(r'\b(status|check|working|work|valid|test|ok)\b') ||
        has(r'^(check |test )?(my )?(ai|vibe ai|vibe) (status|health|check)$') ||
        has(r'^(check|test) (my )?(ai|api|apis|keys)( keys)?$') ||
        has(r'^(vibe )?status( check)?$')) {
      await _checkStatus();
      return true;
    }
    return false;
  }

  Future<void> _applySetting(String s) async {
    await Future.delayed(const Duration(milliseconds: 200));
    switch (s) {
      case 'dark_mode':
        prefs.setTheme(ThemeMode.dark);
        _say('🌙 Dark mode on.');
      case 'light_mode':
        prefs.setTheme(ThemeMode.light);
        _say('☀️ Light mode on.');
      case 'follow_system_theme':
        prefs.setTheme(ThemeMode.system);
        _say('🌗 Following your phone\'s theme now.');
      case 'offline_mode_on':
        prefs.setOfflineMode(true);
        _say('📴 Offline mode on. I won\'t use the internet; questions wait until you turn it off.');
      case 'offline_mode_off':
        prefs.setOfflineMode(false);
        _say('📶 Offline mode off.');
        _drainQueue();
      case 'compact_on':
        prefs.setCompact(true);
        _say('Compact messages on.');
      case 'compact_off':
        prefs.setCompact(false);
        _say('Comfy spacing on.');
      case 'main_ai_gemini' || 'main_ai_groq' || 'main_ai_cloudflare':
        final ai = s.substring('main_ai_'.length);
        final missing = (ai == 'gemini' && prefs.geminiKey.isEmpty) ||
            (ai == 'groq' && prefs.groqKey.isEmpty) ||
            (ai == 'cloudflare' && !Gemini.cloudflareChat);
        if (missing) {
          _say('There\'s no ${ai == 'gemini' ? 'Gemini' : ai == 'groq' ? 'Groq' : 'Cloudflare'} key yet. Add it in Vibe settings → Vibe AI.',
              error: true);
        } else {
          prefs.setMainAi(ai);
          _say('Main AI is now ${ai == 'gemini' ? 'Gemini' : ai == 'groq' ? 'Groq' : 'Cloudflare'}.');
        }
      default:
        _say('I can\'t change that one from chat yet. It\'s in Vibe settings.');
    }
  }

  /// Tests every AI key for real and shows a status card.
  Future<void> _checkStatus({bool withModel = true}) async {
    setState(() => _thinking = true);
    try {
      final online = !prefs.offlineMode && await Native.online();
      Future<Map> row(String label, bool set, Future<String?> Function() test) async {
        if (!set) return {'label': label, 'value': 'Not set', 'ok': null};
        if (!online) return {'label': label, 'value': 'Set · can\'t test offline', 'ok': null};
        final err = await test();
        return {'label': label, 'value': err ?? 'Working', 'ok': err == null};
      }

      final rows = await Future.wait([
        row('Gemini', prefs.geminiKey.isNotEmpty, () async => await Gemini.listModels() == null ? 'Key not working' : null),
        row('Groq', prefs.groqKey.isNotEmpty, () async => await Gemini.listGroqModels() == null ? 'Key not working' : null),
        row('Cloudflare', prefs.cfToken.isNotEmpty || prefs.cfAccount.isNotEmpty, Gemini.checkCloudflare),
        row('OpenRouter (backup)', prefs.routerKey.isNotEmpty, Gemini.checkRouter),
      ]);
      final main = {'gemini': 'Gemini', 'groq': 'Groq', 'cloudflare': 'Cloudflare'}[prefs.mainAi] ?? 'Gemini';
      rows.add({'label': 'Main AI', 'value': main, 'ok': null});
      if (withModel) {
        final st = await Native.nanoStatus();
        _nano = st;
        rows.add({
          'label': 'Offline AI (Gemini Nano)',
          'value': {
                'available': 'Installed',
                'downloadable': 'Not downloaded',
                'downloading': 'Downloading…',
              }[st] ??
              'Not available on this phone',
          'ok': st == 'available' ? true : null,
        });
      }
      final bad = rows.where((r) => r['ok'] == false).length;
      _say(bad == 0 ? 'Here\'s how Vibe AI is doing:' : 'Here\'s how Vibe AI is doing. $bad key${bad == 1 ? '' : 's'} need${bad == 1 ? 's' : ''} attention:',
          card: {'type': 'status', 'rows': rows});
      if (withModel && _nano == 'downloadable') {
        _say('Want to download the offline AI so I can answer without internet?', card: {
          'type': 'ask',
          'state': 'ask',
          'buttons': [
            {'label': 'Show models', 'do': 'nano_models', 'primary': true},
            {'label': 'Not now', 'do': 'cancel'},
          ],
        });
      }
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  /// "Is the offline AI downloaded?" → status, offer to download, model list, progress, done.
  Future<void> _offlineModel({bool wantDownload = false}) async {
    final st = await Native.nanoStatus();
    setState(() => _nano = st);
    await Future.delayed(const Duration(milliseconds: 200));
    switch (st) {
      case 'available':
        _say('✅ The offline AI (Gemini Nano) is installed. I can answer without internet, and nothing leaves your phone.',
            local: true);
      case 'downloading':
        _say('⏬ The offline AI is downloading right now. I\'ll tell you when it\'s ready.');
        if (!_nanoBusy) _startNanoDownload();
      case 'downloadable':
        if (wantDownload) {
          _showModels();
        } else {
          _say('The offline AI isn\'t downloaded yet. Want to download it?', card: {
            'type': 'ask',
            'state': 'ask',
            'buttons': [
              {'label': 'Yes, show models', 'do': 'nano_models', 'primary': true},
              {'label': 'Not now', 'do': 'cancel'},
            ],
          });
        }
      default:
        final info = await Native.nanoInfo();
        final err = '${info['error'] ?? ''}';
        final aicore = '${info['aicore'] ?? '?'}';
        _say('The offline AI isn\'t ready on this phone yet. Your ${info['model']} supports it; Google installs it through '
            '**Android AICore**, which needs updating first.\n\n'
            '• Status: ${info['status']}${err.isEmpty ? '' : ' ($err)'}\n'
            '• Android AICore: $aicore\n'
            '• Private Compute Services: ${info['pcs']}\n\n'
            'These two don\'t show in Play Store search, so use the buttons. After updating, restart the phone and tap Check again. '
            'Google sometimes turns it on a day or two later.',
            card: {
              'type': 'ask',
              'state': 'ask',
              'buttons': [
                {'label': 'Update AICore', 'do': 'upd_aicore', 'primary': true},
                {'label': 'Update Private Compute', 'do': 'upd_pcs'},
                {'label': 'Check again', 'do': 'nano_check'},
              ],
            });
    }
  }

  void _showModels() {
    _say('Offline AI models for your phone:', card: {
      'type': 'models',
      'items': [
        {
          'id': 'gemini-nano',
          'name': 'Gemini Nano',
          'sub': 'By Google · runs fully on your phone · private · Wi-Fi recommended',
        },
      ],
    });
  }

  void _setCard(Msg m, Map card, {String? text}) {
    // [m] may already have been swapped for an updated copy: find the current one
    final cur = chat.msgs.lastWhere((x) => identical(x, m) || (x.ts == m.ts && x.me == m.me && x.text == m.text),
        orElse: () => m);
    final j = cur.toJson();
    j['x'] = card;
    if (text != null) j['t'] = text;
    chat.replace(cur, Msg.fromJson(j));
  }

  Msg? _msgWithCard(String id) {
    for (final m in chat.msgs.reversed) {
      if (m.card?['id'] == id) return m;
    }
    return null;
  }

  void _onAsk(Msg m, String action) {
    // Buttons you can use again and again (call, open…) stay active; one-time choices lock
    const repeat = {'upd_aicore', 'upd_pcs', 'nano_check', 'numcall', 'nummsg', 'numsave', 'numpad', 'tgfileopen', 'tgdownloads', 'tgopen', 'tgstart'};
    if (!repeat.contains(action)) _setCard(m, Map.from(m.card!)..['state'] = action);
    switch (action) {
      case 'nano_models':
        _showModels();
      case 'cancel':
        _say('Okay. Ask me "download offline model" anytime.');
      case 'upd_aicore':
        Native.openUrl('market://details?id=com.google.android.aicore');
      case 'upd_pcs':
        Native.openUrl('market://details?id=com.google.android.as.oss');
      case 'nano_check':
        _offlineModel();
      case 'numcall' || 'nummsg' || 'numsave' || 'numpad':
        final n = '${m.card!['number']}';
        if (action == 'numcall') {
          Native.call(n);
        } else if (action == 'nummsg') {
          _doPeople(PeopleCmd('message', name: n), _personForNumber(n), '');
        } else if (action == 'numsave') {
          Native.addContact(n);
        } else {
          _openDialer(n);
        }
      case 'tgfileopen':
        Native.openFile('${m.card!['uri']}', '${m.card!['mime']}');
      case 'tgdownloads':
        _openTelegramChats(tab: 2);
      case 'tgjoin':
        _tgJoinFromCard(m);
      case 'tgstart':
        _openTelegramChat((m.card!['chat'] as num).toInt(), start: '${m.card!['start'] ?? ''}');
      case 'tgsend':
        _tgSendFromCard(m);
      case 'tgopen':
        _openTelegramChat((m.card!['chat'] as num).toInt());
      case 'tglogin':
        _openTelegramLogin();
      case 'savekey':
        _saveKey('${m.card!['id']}');
      case 'dropkey':
        _pendingKeys.remove('${m.card!['id']}');
        _say('Okay, not saved.');
    }
  }

  void _pickModel(Msg m, Map item) {
    _setCard(m, Map.from(m.card!)..['picked'] = item['id']);
    final id = '${item['id']}';
    switch (m.card!['kind']) {
      case 'gemini':
        prefs.setGeminiModel(id == Gemini.defaultModel ? '' : id);
        _say('Gemini model is now ${item['name']}.');
      case 'groq':
        prefs.setGroqModel(id == Gemini.groqDefault ? '' : id);
        _say('Groq model is now $id.');
      case 'iconpack':
        prefs.setIconPack(id);
        _say(id.isEmpty ? 'Back to system icons.' : 'Icon pack set: ${item['name']}.');
        _refresh();
      case 'unhide':
        if (prefs.hidden.contains(id)) prefs.toggleHidden(id);
        _say('${item['name']} is back in your apps.');
      case 'unmute':
        if (prefs.muted.contains(id)) prefs.toggleMuted(id);
        _say('${item['name']} notifications show here again.');
      default:
        _startNanoDownload();
    }
  }

  Future<void> _reply(String t, {Map? card, List<String> apps = const [], bool error = false}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    _say(t, card: card, apps: apps, error: error);
  }

  /// On / off from words like "on", "enable", "off", "stop", "don't". Null = not said.
  bool? _onOff(String low) {
    if (RegExp(r'\b(off|disable|disabled|stop|no|don t|dont|do not|never|hide|without)\b').hasMatch(low)) return false;
    if (RegExp(r'\b(on|enable|enabled|start|yes|show|turn on|use|with)\b').hasMatch(low)) return true;
    return null;
  }

  AppEntry? _appFrom(String name) {
    final found = Brain.match(Brain.norm(name), _apps);
    return found.isEmpty ? null : found.first.app;
  }

  static const _accentNames = {
    'blurple': 0, 'blue': 0, 'indigo': 0, 'green': 1, 'pink': 2, 'yellow': 3, 'gold': 3,
    'orange': 4, 'sky': 5, 'light blue': 5, 'cyan': 5, 'purple': 6, 'violet': 6, 'red': 7,
  };

  /// Everything else in Vibe settings that chat can change. [low] is normalised, [raw] as typed.
  Future<bool> _moreSettings(String low, String raw) async {
    bool has(String re) => RegExp(re).hasMatch(low);
    RegExpMatch? m(String re) => RegExp(re).firstMatch(low);
    final onOff = _onOff(low);

    // ----- Appearance -----
    final acc = m(r'^(?:set |change |make )?(?:the |my )?(?:accent|theme colou?r|app colou?r|colou?r)(?: colou?r)?(?: to)? (blurple|blue|indigo|green|pink|yellow|gold|orange|sky|light blue|cyan|purple|violet|red)$') ??
        m(r'^(blurple|blue|indigo|green|pink|yellow|gold|orange|sky|light blue|cyan|purple|violet|red) (accent|theme colou?r)$');
    if (acc != null) {
      final i = _accentNames[acc.group(1)]!;
      prefs.setAccent(VC.accents[i].toARGB32());
      await _reply('🎨 Accent colour is now ${acc.group(1)}.');
      return true;
    }
    if (has(r'\bround (app )?icons?\b') && onOff != null) {
      prefs.setRoundIcons(onOff);
      await _reply(onOff ? 'Icons are round now.' : 'Icons keep their own shape now.');
      return true;
    }
    if (has(r'\b(haptics?|vibration on taps?|tap vibrations?|vibrate on taps?)\b') && onOff != null) {
      prefs.setHaptics(onOff);
      await _reply(onOff ? 'Haptics on.' : 'Haptics off.');
      return true;
    }
    if (has(r'\b(remove|clear|delete|reset) (the |my )?wallpaper\b') || has(r'^no wallpaper$')) {
      prefs.setWallpaper('');
      await _reply('Wallpaper removed.');
      return true;
    }
    if (has(r'\bwallpaper\b') && has(r'\b(dim|darker|brighter|lighter|dimmer)\b')) {
      int level = prefs.wallDim;
      if (has(r'\b(light|lighter|brighter|less|low)\b')) {
        level = has(r'\b(lighter|brighter|less)\b') ? (level - 1).clamp(0, 2) : 0;
      } else if (has(r'\b(medium|middle)\b')) {
        level = 1;
      } else if (has(r'\b(strong|max|more|darker|high)\b')) {
        level = has(r'\b(more|darker)\b') ? (level + 1).clamp(0, 2) : 2;
      } else {
        level = (level + 1).clamp(0, 2);
      }
      prefs.setWallDim(level);
      await _reply('Wallpaper dim: ${['light', 'medium', 'strong'][level]}.');
      return true;
    }
    if (has(r'\b(list|show|which|my)\b.*\bicon packs?\b') || has(r'^icon packs?$')) {
      final packs = await Native.iconPacks();
      if (packs.isEmpty) {
        await _reply('You have no icon packs installed. Say "ps icon pack" to find some.');
      } else {
        await _reply('Your icon packs. Tap one to use it:', card: {
          'type': 'models',
          'kind': 'iconpack',
          'items': [
            {'id': '', 'name': 'System icons', 'sub': 'Each app\'s own icon'},
            for (final p in packs) {'id': '${p['package']}', 'name': '${p['label']}', 'sub': 'Icon pack'},
          ],
        });
      }
      return true;
    }
    if (has(r'\b(system icons|default icons|remove (the )?icon pack|no icon pack)\b')) {
      prefs.setIconPack('');
      _refresh();
      await _reply('Back to system icons.');
      return true;
    }
    final ip = m(r'^(?:use|set|apply|change to) (?:the )?(?:icon pack )?(.+?)(?: icon pack| icons)?$');
    if (ip != null && has(r'\bicon')) {
      final packs = await Native.iconPacks();
      final q = Brain.norm(ip.group(1)!.replaceAll('icon pack', ''));
      final hit = packs.where((p) => Brain.norm('${p['label']}').contains(q) && q.isNotEmpty).toList();
      if (hit.isEmpty) {
        await _reply('I couldn\'t find an icon pack called "${ip.group(1)}". Say "list my icon packs".');
      } else {
        prefs.setIconPack('${hit.first['package']}');
        _refresh();
        await _reply('Icon pack set: ${hit.first['label']}.');
      }
      return true;
    }
    if (has(r'\b(compact|comfy|cozy|spacious) (messages|chat|spacing|mode|view)\b') || has(r'^(compact|comfy)$')) {
      final compact = has(r'\bcompact\b') && onOff != false;
      prefs.setCompact(compact);
      await _reply(compact ? 'Compact messages on.' : 'Comfy spacing on.');
      return true;
    }

    // ----- Apps -----
    if (has(r'\bsort\b') && has(r'\bapps?\b|^sort')) {
      if (has(r'\b(a ?to ?z|a z|alphabetical|alphabetically|by name|name)\b')) {
        prefs.setSort(SortMode.az);
        await _reply('Apps are sorted A–Z.');
        return true;
      }
      if (has(r'\b(recent|recently|last used|usage)\b')) {
        prefs.setSort(SortMode.recent);
        await _reply('Apps are sorted by recently opened.');
        return true;
      }
    }
    if (has(r'^(show |list |my |see )*hidden apps$') || has(r'^what apps are hidden$')) {
      final hidden = _apps.where((a) => prefs.hidden.contains(a.pkg)).toList();
      if (hidden.isEmpty) {
        await _reply('No apps are hidden.');
      } else {
        await _reply('Hidden apps. Tap one to bring it back:', card: {
          'type': 'models',
          'kind': 'unhide',
          'items': [for (final a in hidden) {'id': a.pkg, 'name': a.label, 'sub': 'Hidden from your app list'}],
        });
      }
      return true;
    }
    final unhide = m(r'^unhide (?:the )?(.+?)(?: app)?$');
    if (unhide != null) {
      final a = _apps.where((x) => prefs.hidden.contains(x.pkg)).toList();
      final found = Brain.match(Brain.norm(unhide.group(1)!), a);
      if (found.isEmpty) {
        await _reply('"${unhide.group(1)}" isn\'t hidden.');
      } else {
        prefs.toggleHidden(found.first.app.pkg);
        await _reply('${found.first.app.label} is back in your apps.', apps: [found.first.app.pkg]);
      }
      return true;
    }
    final hide = m(r'^hide (?:the )?(.+?)(?: app| from (?:my )?apps)?$');
    if (hide != null && !has(r'\bnotifications?\b|\bkeyboard\b')) {
      final a = _appFrom(hide.group(1)!);
      if (a == null) {
        await _reply('I couldn\'t find an app called "${hide.group(1)}".');
      } else {
        if (!prefs.hidden.contains(a.pkg)) prefs.toggleHidden(a.pkg);
        await _reply('${a.label} is hidden. Say "unhide ${a.label}" to bring it back.');
      }
      return true;
    }

    // ----- Notifications -----
    if (has(r'^(show |list |my |see )*muted apps$')) {
      final muted = _apps.where((a) => prefs.muted.contains(a.pkg)).toList();
      if (muted.isEmpty) {
        await _reply('No apps are muted.');
      } else {
        await _reply('Muted apps. Tap one to unmute it:', card: {
          'type': 'models',
          'kind': 'unmute',
          'items': [for (final a in muted) {'id': a.pkg, 'name': a.label, 'sub': 'Notifications hidden here'}],
        });
      }
      return true;
    }
    final unmute = m(r'^unmute (?:the )?(.+?)(?: app| notifications)?$');
    if (unmute != null) {
      final a = _appFrom(unmute.group(1)!);
      if (a == null || !prefs.muted.contains(a.pkg)) {
        await _reply('"${unmute.group(1)}" isn\'t muted.');
      } else {
        prefs.toggleMuted(a.pkg);
        await _reply('${a.label} notifications show here again.');
      }
      return true;
    }
    final mute = m(r'^mute (?:the )?(.+?)(?: app)?(?: notifications)?$');
    if (mute != null && !has(r'^mute (the )?(phone|volume|sound|ringer|media)')) {
      final a = _appFrom(mute.group(1)!);
      if (a == null) {
        await _reply('I couldn\'t find an app called "${mute.group(1)}".');
      } else {
        if (!prefs.muted.contains(a.pkg)) prefs.toggleMuted(a.pkg);
        await _reply('Muted ${a.label}. Its notifications won\'t show here. Say "unmute ${a.label}" to undo.');
      }
      return true;
    }
    if (has(r'\b(music|song|songs|media) (updates|messages|notifications)\b') && onOff != null) {
      prefs.setShowMedia(onOff);
      await _reply(onOff ? '🎵 Music updates on.' : 'Music updates off.');
      return true;
    }
    if (has(r'\b(ai|gemini|vibe ai)\b') && has(r'\bread\b') && has(r'\bnotifications?\b')) {
      final allow = !has(r'\b(don t|dont|do not|stop|never|no)\b');
      prefs.setAiNotifs(allow);
      await _reply(allow
          ? 'Vibe AI can read your recent notifications now (OTPs and bank alerts are still kept back).'
          : '🔒 Vibe AI won\'t read your notifications anymore.');
      return true;
    }
    if (has(r'\bnotification access\b')) {
      await _reply('Opening notification access. Turn Vibe on there.');
      Native.openNotifAccess();
      return true;
    }
    if (has(r'\bnotifications?\b') && !has(r'\bsettings?\b|\bmusic\b|\bmuted?\b') &&
        has(r'^(stop showing|stop|hide|don t show|dont show|do not show|show|turn (on|off)|enable|disable)\b|\b(in (the )?chat|here)\b|^notifications? (on|off)$')) {
      final show = !has(r'\b(stop|hide|don t|dont|do not|off|disable)\b');
      prefs.setShowNotifs(show);
      await _reply(show ? 'Notifications show in chat again.' : 'Notifications won\'t show in chat anymore.');
      return true;
    }

    // ----- People -----
    final via = m(r'^(?:make |set )?(?:messages?|messaging|texts?|message someone)(?: should)? (?:use|uses|go (?:via|through)|by default use|default to) (whatsapp|sms)$') ??
        m(r'^(?:always )?use (whatsapp|sms) (?:for|to send) (?:messages?|messaging|texts?)$');
    if (via != null) {
      final w = via.group(1)!.contains('whatsapp') ? 'whatsapp' : 'sms';
      prefs.setMessenger(w);
      await _reply('"Message someone" now uses ${w == 'whatsapp' ? 'WhatsApp' : 'SMS'}.');
      return true;
    }

    // ----- Daily brief -----
    final briefOnOff = has(r'\b(off|disable|stop|turn off|no more)\b')
        ? false
        : has(r'\b(on|enable|turn on|start)\b')
            ? true
            : null;
    if (has(r'\b(daily |morning )?brief\b') && (briefOnOff != null || has(r'\bat \d'))) {
      final onOff = briefOnOff;
      final t = RegExp(r'\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b')
          .firstMatch(low.replaceAllMapped(RegExp(r'(\d) (\d{2})\b'), (x) => '${x.group(1)}:${x.group(2)}'));
      if (has(r'\bat \d') && t != null) {
        var h = int.parse(t.group(1)!);
        final min = int.tryParse(t.group(2) ?? '') ?? 0;
        if (t.group(3) == 'pm' && h < 12) h += 12;
        if (t.group(3) == 'am' && h == 12) h = 0;
        if (h > 23 || min > 59) return false;
        prefs.setBrief(true, hour: h, minute: min);
        Native.requestPostNotif();
        await scheduleBrief();
        await _reply('☀️ Daily brief every day at ${TimeOfDay(hour: h, minute: min).format(context)}.');
        return true;
      }
      if (onOff != null) {
        prefs.setBrief(onOff);
        if (onOff) Native.requestPostNotif();
        await scheduleBrief();
        await _reply(onOff
            ? '☀️ Daily brief on, at ${TimeOfDay(hour: prefs.briefHour, minute: prefs.briefMinute).format(context)}.'
            : 'Daily brief off.');
        return true;
      }
    }

    // ----- Vibe AI -----
    if (has(r'\b(list|show|which)\b.*\bgemini models?\b') || has(r'^gemini models?$')) {
      final list = await Gemini.listModels();
      if (list == null) {
        await _reply('I couldn\'t load Gemini models. Check your key with "check my AI keys".', error: true);
      } else {
        await _reply('Gemini models on your key. Tap one to use it:', card: {
          'type': 'models',
          'kind': 'gemini',
          'items': [
            {'id': Gemini.defaultModel, 'name': 'Default (newest Flash)', 'sub': Gemini.defaultModel},
            for (final x in list.where((x) => x.id != Gemini.defaultModel).take(12))
              {'id': x.id, 'name': x.label, 'sub': x.id},
          ],
        });
      }
      return true;
    }
    if (has(r'\b(list|show|which)\b.*\bgroq models?\b') || has(r'^groq models?$')) {
      final list = prefs.groqKey.isEmpty ? null : await Gemini.listGroqModels();
      if (list == null) {
        await _reply('I couldn\'t load Groq models. Add or check your Groq key first.', error: true);
      } else {
        await _reply('Groq models (all free). Tap one to use it:', card: {
          'type': 'models',
          'kind': 'groq',
          'items': [for (final x in list) {'id': x, 'name': x, 'sub': x == Gemini.groqDefault ? 'Default' : 'Groq'}],
        });
      }
      return true;
    }
    final gm = m(r'^(?:use|switch to|change to) (?:gemini )?(flash lite|flash-lite|flashlite|flash|pro)(?: model)?$');
    if (gm != null && (low.contains('gemini') || (low.contains('flash') && low.contains('lite')))) {
      final g = gm.group(1)!;
      final id = g.startsWith('flash') && g.contains('lite')
          ? Gemini.fallbackModel
          : g == 'pro'
              ? 'gemini-pro-latest'
              : Gemini.defaultModel;
      prefs.setGeminiModel(id == Gemini.defaultModel ? '' : id);
      await _reply('Gemini model is now $id.${g == 'pro' ? ' Pro has a much smaller free limit.' : ''}');
      return true;
    }
    final main = m(r'^(?:use|switch to|change to|make|set) (?:the )?(?:main ai (?:to )?)?(gemini|groq|cloudflare)(?: (?:as )?(?:the )?(?:main )?(?:ai|brain))?$');
    if (main != null) {
      await _applySetting('main_ai_${main.group(1)}');
      return true;
    }
    if (has(r'\bcloudflare (chat|ai)\b') && onOff != null) {
      prefs.setCfChat(onOff);
      if (!onOff && prefs.mainAi == 'cloudflare') prefs.setMainAi('gemini');
      await _reply(onOff ? 'Cloudflare chat on.' : 'Cloudflare chat off. Pictures still work.');
      return true;
    }

    // ----- Backup -----
    if (has(r'^(please )?(back ?up|backup)( now| (my )?(chat|vibe|settings|everything))*$')) {
      final d = DateTime.now();
      final name =
          'vibe-backup-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.json';
      await _reply('Pick where to save the backup (keys aren\'t included; they stay encrypted on this phone).');
      final ok = await Native.saveDoc(name, await Backup.export());
      _say(ok ? '✅ Backup saved as $name.' : 'Backup not saved.', error: !ok);
      return true;
    }

    // ----- Home app -----
    if (has(r'\b(make|set|use) (vibe|this|this app|it)( as)?( my| the)? (default |home )+(app|launcher|screen)?\b') ||
        has(r'^(make |set )?(vibe|this) (my )?(home app|default launcher|launcher)$')) {
      if (await Native.isDefault()) {
        await _reply('Vibe is already your home app. 🏠');
      } else {
        await _reply('Opening home app settings. Pick Vibe Launcher there.');
        Native.openHomeSettings();
      }
      return true;
    }
    return false;
  }

  // ---------- API keys typed into the chat ----------
  final Map<String, (String, String)> _pendingKeys = {}; // card id → (which, key). Never saved to disk.

  static final _keyRes = <(String, RegExp)>[
    ('gemini', RegExp(r'\bAIza[0-9A-Za-z_\-]{30,}')),
    ('groq', RegExp(r'\bgsk_[A-Za-z0-9]{20,}')),
    ('openrouter', RegExp(r'\bsk-or-v1-[A-Za-z0-9]{20,}')),
    ('cfaccount', RegExp(r'(?<![0-9a-fA-F])[0-9a-fA-F]{32}(?![0-9a-fA-F])')),
    ('cftoken', RegExp(r'(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{40}(?![A-Za-z0-9_\-])')),
  ];
  static const _keyNames = {
    'gemini': 'Gemini API key',
    'groq': 'Groq API key',
    'openrouter': 'OpenRouter key',
    'cfaccount': 'Cloudflare account ID',
    'cftoken': 'Cloudflare API token',
  };

  /// "my groq key is gsk_…": shows a hidden version and asks before saving. True when handled.
  Future<bool> _keyInChat(String text) async {
    final low = text.toLowerCase();
    for (final (which, re) in _keyRes) {
      final k = re.firstMatch(text);
      if (k == null) continue;
      // The two Cloudflare ones are plain-looking, so they need the word "cloudflare"
      if (which.startsWith('cf') && !low.contains('cloudflare')) continue;
      if (which == 'cfaccount' && !low.contains('account')) continue;
      if (which == 'cftoken' && !low.contains('token')) continue;
      final key = k.group(0)!;
      final masked = text.replaceAll(key, '${key.substring(0, 4)}••••${key.substring(key.length - 4)}');
      chat.add(Msg(true, masked));
      _toBottom();
      final id = 'key${DateTime.now().millisecondsSinceEpoch}';
      _pendingKeys[id] = (which, key);
      await _reply('Save this as your ${_keyNames[which]}? It\'s stored encrypted on this phone, never in the chat.', card: {
        'type': 'ask',
        'id': id,
        'state': 'ask',
        'buttons': [
          {'label': 'Save key', 'do': 'savekey', 'primary': true},
          {'label': 'Cancel', 'do': 'dropkey'},
        ],
      });
      return true;
    }
    return false;
  }

  Future<void> _saveKey(String id) async {
    final p = _pendingKeys.remove(id);
    if (p == null) {
      _say('That key wasn\'t kept (Vibe restarted). Paste it again.', error: true);
      return;
    }
    final (which, key) = p;
    switch (which) {
      case 'gemini':
        prefs.setGeminiKey(key);
      case 'groq':
        prefs.setGroqKey(key);
      case 'openrouter':
        prefs.setRouterKey(key);
      case 'cfaccount':
        prefs.setCloudflare(key, prefs.cfToken);
      case 'cftoken':
        prefs.setCloudflare(prefs.cfAccount, key);
    }
    _say('🔐 Saved your ${_keyNames[which]}. Checking it…');
    await _checkStatus(withModel: false);
  }

  bool _nanoBusy = false;

  Future<void> _startNanoDownload() async {
    if (_nanoBusy) return;
    _nanoBusy = true;
    final id = 'dl${DateTime.now().millisecondsSinceEpoch}';
    _say('Downloading Gemini Nano. Keep Wi-Fi on; you can keep using Vibe.',
        card: {'type': 'progress', 'id': id, 'title': 'Gemini Nano', 'done': 0, 'total': 0, 'state': 'running'});
    var last = 0;
    var total = 0;
    Native.onNanoProgress = (done, t) {
      if (t > 0) total = t;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < 700) return; // a few updates a second is plenty
      last = now;
      final m = _msgWithCard(id);
      if (m != null) _setCard(m, Map.from(m.card!)..['done'] = done..['total'] = total);
    };
    var ok = false;
    try {
      ok = await Native.nanoDownload();
    } catch (_) {}
    Native.onNanoProgress = null;
    _nanoBusy = false;
    final st = await Native.nanoStatus();
    if (mounted) setState(() => _nano = st);
    final m = _msgWithCard(id);
    if (m != null) _setCard(m, Map.from(m.card!)..['state'] = ok || st == 'available' ? 'done' : 'failed');
    if (ok || st == 'available') {
      _say('🎉 Offline model installed! I can now answer without internet, and nothing leaves your phone.', local: true);
    } else {
      _say('The download didn\'t finish. Check Wi-Fi and storage, then say "download offline model" to try again.',
          error: true);
    }
  }

  // ---------- Apps that talk: Play Store, Google, YouTube, Maps, Settings ----------
  static const _playPkg = 'com.android.vending';
  static const _chromePkg = 'com.android.chrome';
  static const _googlePkg = 'com.google.android.googlequicksearchbox';
  static const _ytPkg = 'com.google.android.youtube';
  static const _mapsPkg = 'com.google.android.apps.maps';
  static const _settingsPkg = 'com.android.settings';

  /// Posts a message from an app itself (its icon and name), e.g. Play Store: "Opening search results…".
  void _appSays(String pkg, String name, String text, {Map? action}) {
    chat.add(Msg(false, text,
        pkg: pkg, app: _byPkg(pkg)?.label ?? name, talk: true, card: {'type': 'talk', ...?action}));
    _toBottom();
  }

  Future<void> _doTalk(Map a, String pkg) async {
    prefs.tap();
    if (a['url'] != null) {
      await Native.openUrl(a['url'].toString(), pkg: a['open']?.toString());
    } else if (a['settings'] != null) {
      await Native.openSettingsPage(a['settings'].toString());
    } else {
      final app = _byPkg(pkg);
      if (app != null) _launch(app);
    }
  }

  Future<void> _talkAndOpen(String pkg, String name, String text, Map action) async {
    _focus.unfocus();
    _appSays(pkg, name, text, action: action);
    await _shown();
    await _doTalk(action, pkg);
  }

  Future<void> _playStore(String q) async {
    if (q.isEmpty) {
      await _talkAndOpen(_playPkg, 'Google Play Store', 'Opening Play Store…', {});
      return;
    }
    await _talkAndOpen(_playPkg, 'Google Play Store', 'Opening search results for "$q"',
        {'url': 'market://search?q=${Uri.encodeComponent(q)}&c=apps', 'open': _playPkg});
  }

  Future<void> _google(String q) async {
    final chrome = _byPkg(_chromePkg) != null;
    final who = chrome ? _chromePkg : (_byPkg(_googlePkg) != null ? _googlePkg : _chromePkg);
    await _talkAndOpen(who, chrome ? 'Chrome' : 'Google', 'Searching Google for "$q"',
        {'url': 'https://www.google.com/search?q=${Uri.encodeComponent(q)}', if (chrome) 'open': _chromePkg});
  }

  static const _settingsPages = <(String, String, String)>[
    (r'wi ?fi|wireless', 'android.settings.WIFI_SETTINGS', 'Wi-Fi'),
    (r'bluetooth|bt', 'android.settings.BLUETOOTH_SETTINGS', 'Bluetooth'),
    (r'hotspot|tethering|mobile data|sim|network', 'android.settings.WIRELESS_SETTINGS', 'Network'),
    (r'display|brightness|screen timeout|dark mode', 'android.settings.DISPLAY_SETTINGS', 'Display'),
    (r'sound|volume|ringtone|vibration', 'android.settings.SOUND_SETTINGS', 'Sound'),
    (r'battery|power', 'android.intent.action.POWER_USAGE_SUMMARY', 'Battery'),
    (r'storage|space', 'android.settings.INTERNAL_STORAGE_SETTINGS', 'Storage'),
    (r'apps?|applications', 'android.settings.APPLICATION_SETTINGS', 'Apps'),
    (r'notifications?', 'android.settings.NOTIFICATION_SETTINGS', 'Notifications'),
    (r'location|gps', 'android.settings.LOCATION_SOURCE_SETTINGS', 'Location'),
    (r'date|time|date and time', 'android.settings.DATE_SETTINGS', 'Date & time'),
    (r'language|languages|keyboard', 'android.settings.LOCALE_SETTINGS', 'Languages'),
    (r'developer|developer options', 'android.settings.APPLICATION_DEVELOPMENT_SETTINGS', 'Developer options'),
    (r'about( phone)?|phone info', 'android.settings.DEVICE_INFO_SETTINGS', 'About phone'),
    (r'security|lock screen|fingerprint|face unlock', 'android.settings.SECURITY_SETTINGS', 'Security'),
    (r'accessibility', 'android.settings.ACCESSIBILITY_SETTINGS', 'Accessibility'),
    (r'nfc', 'android.settings.NFC_SETTINGS', 'NFC'),
    (r'vpn', 'android.settings.VPN_SETTINGS', 'VPN'),
    (r'default apps|home app|launcher', 'android.settings.HOME_SETTINGS', 'Home app'),
  ];

  /// "ps whatsapp", "gg cricket score", "yt lofi", "maps petrol pump", "wifi settings". False = not one of these.
  Future<bool> _appCommands(String text) async {
    final t = text.trim();
    RegExpMatch? m(String re) => RegExp(re, caseSensitive: false).firstMatch(t);
    final ps = m(r'^(?:ps|playstore|play store|search (?:the )?play ?store(?: for)?|install)(?:\s+(.*))?$');
    if (ps != null) {
      await _playStore((ps.group(1) ?? '').trim());
      return true;
    }
    final gg = m(r'^(?:gg|google|google search|search google(?: for)?)\s+(.+)$');
    if (gg != null) {
      await _google(gg.group(1)!.trim());
      return true;
    }
    final yt = m(r'^(?:yt|youtube search|search youtube(?: for)?)\s+(.+)$');
    if (yt != null) {
      final q = yt.group(1)!.trim();
      await _talkAndOpen(_ytPkg, 'YouTube', 'Searching YouTube for "$q"',
          {'url': 'https://www.youtube.com/results?search_query=${Uri.encodeComponent(q)}', 'open': _ytPkg});
      return true;
    }
    final nav = m(r'^(?:navigate to|directions to|take me to)\s+(.+)$');
    if (nav != null) {
      final q = nav.group(1)!.trim();
      await _talkAndOpen(_mapsPkg, 'Maps', 'Starting directions to "$q"',
          {'url': 'google.navigation:q=${Uri.encodeComponent(q)}', 'open': _mapsPkg});
      return true;
    }
    final map = m(r'^(?:maps?|find on maps?|show on maps?)\s+(.+)$');
    if (map != null) {
      final q = map.group(1)!.trim();
      await _talkAndOpen(_mapsPkg, 'Maps', 'Finding "$q"',
          {'url': 'geo:0,0?q=${Uri.encodeComponent(q)}', 'open': _mapsPkg});
      return true;
    }
    final low = Brain.norm(t).replaceFirst(RegExp(r'^(open |show |go to )'), '');
    for (final (re, action, label) in _settingsPages) {
      // Plain words like "apps" or "battery" need "settings" after them; a few are clear on their own
      final bare = RegExp(r'^(wi ?fi|bluetooth|hotspot|nfc|vpn|developer options)$').hasMatch(low);
      if (RegExp('^($re)( settings?| page)?\$').hasMatch(low) && (low.contains('setting') || (bare && !_appNamed(low)))) {
        await _talkAndOpen(_settingsPkg, 'Settings', 'Opening $label settings…', {'settings': action});
        return true;
      }
    }
    return false;
  }

  /// True if an installed app is called exactly this (so "battery" can still open a "Battery" app).
  bool _appNamed(String n) => _apps.any((a) => Brain.norm(a.label) == n);

  // ---------- Live results while you type ----------
  String _liveQ = '';
  List<AppEntry> _lApps = [];
  List<Person> _lPeople = [];
  List<Msg> _lMsgs = [];
  List<Map> _lFiles = [], _lSms = [], _lEvents = [];
  Timer? _liveT;
  int _liveGen = 0;

  void _onTyping() {
    setState(() {});
    var q = _input.text.trim();
    // Strip a leading command word so "open whats" or "call rav" still find things
    final verb = RegExp(r'^(open|launch|call|ring|message|msg|text|whatsapp|find|search|play)\s+', caseSensitive: false)
        .firstMatch(q);
    if (verb != null) q = q.substring(verb.end);
    final off = _replyTo != null || _attachImg != null || _attachText != null || q.length < 2 ||
        q.split(RegExp(r'\s+')).length > 4 ||
        RegExp(r'^(ps|gg|yt|remind|remember|forget|what|who|why|how|when|where|is|are|can|tell)\b', caseSensitive: false)
            .hasMatch(_input.text.trim());
    if (off) {
      if (_liveQ.isNotEmpty) setState(_clearLive);
      return;
    }
    if (q == _liveQ) return;
    final low = q.toLowerCase();
    setState(() {
      _liveQ = q;
      _lApps = Brain.match(Brain.norm(q), _apps).take(4).map((e) => e.app).toList();
      _lPeople = People.match(q).take(3).map((e) => e.p).toList();
      _lMsgs = chat.msgs.reversed
          .where((m) => !m.me && m.text.toLowerCase().contains(low) || (m.title ?? '').toLowerCase().contains(low))
          .take(3)
          .toList();
    });
    _liveT?.cancel();
    final gen = ++_liveGen;
    _liveT = Timer(const Duration(milliseconds: 260), () async {
      final r = await Future.wait([Native.searchFiles(q), Native.searchSms(q), Native.searchEvents(q)]);
      if (!mounted || gen != _liveGen) return;
      setState(() {
        _lFiles = r[0].take(3).toList();
        _lSms = r[1].take(2).toList();
        _lEvents = r[2].take(2).toList();
      });
    });
  }

  void _clearLive() {
    _liveQ = '';
    _lApps = [];
    _lPeople = [];
    _lMsgs = [];
    _lFiles = [];
    _lSms = [];
    _lEvents = [];
    _liveGen++;
  }

  void _liveDone() {
    _input.clear();
    setState(_clearLive);
  }

  /// Results panel that slides up above the message box while you type.
  Widget _livePanel(VC c) {
    final any = _lApps.isNotEmpty || _lPeople.isNotEmpty || _lMsgs.isNotEmpty || _lFiles.isNotEmpty ||
        _lSms.isNotEmpty || _lEvents.isNotEmpty;
    final show = _liveQ.isNotEmpty && any;
    final q = _liveQ;

    Widget row(Widget leading, String title, String? sub, VoidCallback onTap, {Widget? trailing}) => InkWell(
          onTap: () {
            prefs.tap();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              SizedBox(width: 34, height: 34, child: leading),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _hlText(c, title, q, TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 14.5)),
                  if (sub != null)
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.faint, fontSize: 12)),
                ]),
              ),
              if (trailing != null) trailing,
            ]),
          ),
        );
    Widget circle(IconData i, {Color? bg, Color? fg}) => Container(
        decoration: BoxDecoration(color: bg ?? c.card, shape: BoxShape.circle),
        child: Icon(i, size: 18, color: fg ?? c.muted));
    Widget chip(IconData i, String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            avatar: Icon(i, size: 16, color: VC.blurple),
            label: Text(label, style: TextStyle(color: c.text, fontSize: 12.5)),
            backgroundColor: c.card,
            side: BorderSide(color: c.divider),
            onPressed: () {
              prefs.tap();
              onTap();
            },
          ),
        );

    final rows = <Widget>[
      for (final a in _lApps)
        row(appIcon(a, 34), a.label, 'App', () {
          _liveDone();
          _appSays(a.pkg, a.label, 'Opening…');
          _launch(a);
        }),
      for (final p in _lPeople)
        row(PersonAvatar(name: p.name, person: p, size: 34), p.name, p.number, () {
          _liveDone();
          _contactSheet(p);
        },
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.call_rounded, color: VC.green, size: 20),
                  onPressed: () {
                    _liveDone();
                    _doPeople(PeopleCmd('call', name: p.name), p, '');
                  }),
              IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.chat_rounded, color: VC.blurple, size: 20),
                  onPressed: () {
                    _liveDone();
                    Native.whatsapp(p.number, '');
                  }),
            ])),
      for (final m in _lMsgs)
        row(m.pkg != null ? _miniAvatar(c, m.pkg, 34) : const BotAvatar(size: 34),
            Privacy.msg(m) ? '🔒 Private message' : (m.title?.isNotEmpty == true ? '${m.title}: ${m.text}' : m.text),
            '${m.app ?? 'Vibe'} · ${stamp(DateTime.fromMillisecondsSinceEpoch(m.ts))}', () {
          if (m.isNotif) _openNotif(m);
          _liveDone();
        }),
      for (final f in _lFiles)
        row(circle(Icons.description_rounded), f['name'].toString(), 'File', () {
          _liveDone();
          Native.openFile(f['uri'].toString(), f['mime'].toString());
        }),
      for (final sm in _lSms)
        row(circle(Icons.sms_rounded),
            Privacy.text(sm['body'].toString()) ? '🔒 Private SMS' : sm['body'].toString(), 'SMS · ${sm['address']}', () {
          _liveDone();
          Native.smsApp(sm['address'].toString(), '');
        }),
      for (final e in _lEvents)
        row(circle(Icons.event_rounded, fg: VC.blurple), e['title'].toString(),
            stamp(DateTime.fromMillisecondsSinceEpoch((e['begin'] as num?)?.toInt() ?? 0)), () {
          _liveDone();
          Native.openEvent((e['id'] as num?)?.toInt() ?? 0);
        }),
    ];

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, a) => SizeTransition(
        sizeFactor: a,
        axisAlignment: 1,
        child: FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(a),
            child: child,
          ),
        ),
      ),
      child: !show
          ? const SizedBox(key: ValueKey('none'), width: double.infinity)
          : Container(
              key: const ValueKey('live'),
              margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.36),
              decoration: BoxDecoration(
                color: c.pane,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.divider),
                boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 4))],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    alignment: Alignment.bottomCenter,
                    child: ListView(
                      shrinkWrap: true,
                      reverse: true, // best matches sit next to the message box
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: rows,
                    ),
                  ),
                ),
                Container(
                  height: 1,
                  color: c.divider,
                ),
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    children: [
                      chip(Icons.manage_search_rounded, 'All results', () {
                        final qq = q;
                        _liveDone();
                        _openSearch(qq);
                      }),
                      chip(Icons.shop_rounded, 'Play Store', () {
                        final qq = q;
                        _liveDone();
                        _playStore(qq);
                      }),
                      chip(Icons.public_rounded, 'Google', () {
                        final qq = q;
                        _liveDone();
                        _google(qq);
                      }),
                    ],
                  ),
                ),
              ]),
            ),
    );
  }

  Widget _hlText(VC c, String text, String q, TextStyle style) {
    final low = text.toLowerCase(), ql = q.toLowerCase();
    final i = ql.isEmpty || low.length != text.length ? -1 : low.indexOf(ql);
    if (i < 0 || i + q.length > text.length) return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    return Text.rich(
      TextSpan(style: style, children: [
        TextSpan(text: text.substring(0, i)),
        TextSpan(
            text: text.substring(i, i + q.length),
            style: TextStyle(backgroundColor: VC.blurple.withValues(alpha: 0.28), fontWeight: FontWeight.w800)),
        TextSpan(text: text.substring(i + q.length)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  // ---------- Pictures ----------
  Future<void> _draw(String prompt, {bool wallpaper = false}) async {
    if (prompt.trim().isEmpty) {
      _say('What should I draw?');
      return;
    }
    if (!ImageGen.ready) {
      await Future.delayed(const Duration(milliseconds: 250));
      _say('To draw pictures, add your Cloudflare account ID and API token in Vibe settings → Vibe AI → Pictures. '
          'It\'s free with a daily limit.');
      return;
    }
    if (!_netOk) {
      _say(prefs.offlineMode ? '📴 Drawing needs internet, and offline mode is on.' : '📴 Drawing needs internet. You\'re offline.');
      return;
    }
    setState(() {
      _thinking = true;
      _drawing = true;
    });
    _toBottom();
    try {
      final path = await ImageGen.draw(prompt, wallpaper: wallpaper);
      if (!mounted) return;
      _say(wallpaper ? '🎨 Here\'s your wallpaper. Say "set it as wallpaper" to use it.' : '🎨 $prompt', img: path);
    } catch (e) {
      _say('$e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _thinking = false;
          _drawing = false;
        });
      }
    }
  }

  String? get _lastImage {
    for (final m in chat.msgs.reversed) {
      if (m.img != null && File(m.img!).existsSync()) return m.img;
    }
    return null;
  }

  Future<bool> _wallpaperCommand(String text) async {
    final m = RegExp(
            r'^(?:set|use|make|apply)\s+(?:it|this|that|the (?:image|picture|last one))\s+(?:as\s+)?(?:my\s+)?'
            r'(phone |home |lock ?screen |vibe |chat )?(wallpaper|background|lock ?screen)$',
            caseSensitive: false)
        .firstMatch(text.trim());
    if (m == null) return false;
    final path = _lastImage;
    if (path == null) {
      _say('There\'s no picture in the chat to use yet. Ask me to draw one, or send a photo.');
      return true;
    }
    final where = '${m.group(1) ?? ''}${m.group(2)}'.toLowerCase();
    if (where.contains('lock')) {
      final ok = await Native.setWallpaper(path, lockOnly: true);
      _say(ok ? '🔒 Set as your lock screen.' : 'Your phone didn\'t let me change the lock screen.', error: !ok);
    } else if (where.contains('phone')) {
      final ok = await Native.setWallpaper(path);
      _say(ok ? '📱 Set as your phone wallpaper.' : 'Your phone didn\'t let me change the wallpaper.', error: !ok);
    } else {
      prefs.setWallpaper(path);
      _say('✨ Set as the wallpaper behind this chat. Say "set it as lock screen" to use it there too.');
    }
    return true;
  }

  void _imageMenu(String path) {
    prefs.heavy();
    final c = VC.of(context);
    Widget item(IconData i, String label, Future<void> Function() onTap) => ListTile(
          leading: Icon(i, color: c.text),
          title: Text(label, style: TextStyle(color: c.text, fontWeight: FontWeight.w500)),
          onTap: () async {
            Navigator.pop(context);
            await onTap();
          },
        );
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          item(Icons.download_rounded, 'Save to Gallery', () async {
            final uri = await Native.saveToGallery(path);
            _say(uri != null ? '💾 Saved to Gallery → Pictures/Vibe.' : 'Couldn\'t save the picture.', error: uri == null);
          }),
          item(Icons.share_rounded, 'Share', () async {
            final uri = await Native.saveToGallery(path);
            if (uri != null) await Native.shareImage(uri);
          }),
          item(Icons.wallpaper_rounded, 'Use behind this chat', () async {
            prefs.setWallpaper(path);
          }),
          item(Icons.phone_android_rounded, 'Set as phone wallpaper', () async {
            final ok = await Native.setWallpaper(path);
            if (!ok) _say('Your phone didn\'t let me change the wallpaper.', error: true);
          }),
          item(Icons.lock_rounded, 'Set as lock screen', () async {
            final ok = await Native.setWallpaper(path, lockOnly: true);
            if (!ok) _say('Your phone didn\'t let me change the lock screen.', error: true);
          }),
          const SizedBox(height: 8),
        ]),
      ),
    );
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
              // Your wallpaper behind the chat, dimmed so text stays readable
              if (prefs.wallpaper.isNotEmpty && File(prefs.wallpaper).existsSync())
                Positioned.fill(
                  child: Stack(fit: StackFit.expand, children: [
                    Image.file(File(prefs.wallpaper), fit: BoxFit.cover, gaplessPlayback: true),
                    ColoredBox(color: c.chat.withValues(alpha: const [0.45, 0.65, 0.82][prefs.wallDim.clamp(0, 2)])),
                  ]),
                ),
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
                    _livePanel(c),
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
                        child: _AppDrawer(
                          apps: _apps,
                          loaded: _loaded,
                          status: (prefs.offlineMode || !_online) ? 'Offline mode' : 'Online',
                          onSearch: () {
                            _closeDrawer();
                            _openSearch();
                          },
                          onPlayStore: () {
                            _closeDrawer();
                            _playStore('');
                          },
                          onDialer: () {
                            _closeDrawer();
                            _openDialer();
                          },
                          onTelegram: Telegram.i.configured
                              ? () {
                                  _closeDrawer();
                                  _openTelegramChats();
                                }
                              : null,
                          onMissed: () {
                            _closeDrawer();
                            _send('what did I miss?');
                          },
                          onSettings: () {
                            _closeDrawer();
                            _openLauncherSettings();
                          },
                          onLaunch: (a) {
                            _closeDrawer();
                            _launch(a);
                          },
                        ),
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
                      style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 19, shadows: c.nameShadows)),
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
            return Entrance(
                key: const ValueKey('typing'),
                animate: true,
                child: _TypingRowHolder(label: _drawing ? 'Vibe is drawing…' : 'Vibe is typing…'));
          }
          final i = _thinking ? idx - 1 : idx;
          try {
            return _timelineItem(c, msgs, n, i);
          } catch (e, st) {
            noteError(e, st);
            return KeyedSubtree(
              key: ValueKey('bad$i'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(68, 4, 16, 4),
                child: Text('(This message couldn\'t be shown)', style: TextStyle(color: c.faint, fontSize: 13)),
              ),
            );
          }
        },
      ),
    );
  }

  Widget _timelineItem(VC c, List<Msg> msgs, int n, int i) {
          if (n - 1 - i < 0 || n - 1 - i >= msgs.length) return const SizedBox.shrink();
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
  }

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
            onLongPress: () => _imageMenu(m.img!),
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
      row = Padding(padding: EdgeInsets.fromLTRB(68, prefs.compact ? 1 : 4, 16, prefs.compact ? 0 : 2), child: content);
    } else {
      Widget avatar;
      String name;
      if (m.me) {
        avatar = Avatar(name: prefs.name, size: 40, dot: false);
        name = prefs.name;
      } else if (m.pkg != null) {
        // A chat app message from someone in your contacts: their photo with the app as a badge
        final person = m.media || m.talk ? null : People.fromTitle(m.title);
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
        padding: EdgeInsets.fromLTRB(16, hasQuote ? (prefs.compact ? 6 : 10) : (prefs.compact ? 6 : 12), 16, prefs.compact ? 0 : 2),
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
                            color: c.nameColor(m.me),
                            shadows: c.nameShadows,
                            fontWeight: FontWeight.w600,
                            fontSize: 16)),
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
                  if (m.ai != null) ...[
                    const SizedBox(width: 6),
                    Text('· ${m.ai}', style: TextStyle(color: c.faint, fontSize: 11)),
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
      // Keep the finished row in its own variable: the builder runs later, and by then `row`
      // would point at this Builder itself (it then contained itself forever: stack overflow).
      final inner = row;
      row = Builder(
        builder: (ctx) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openNotif(m),
          onLongPress: () => m.media ? _mediaPane(ctx, m) : _notifMenu(m),
          child: inner,
        ),
      );
    } else if (m.talk) {
      // An app talking: tap does the same thing again, long-press shows the app menu
      final app = _byPkg(m.pkg!);
      row = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _doTalk(m.card ?? const {}, m.pkg!),
        onLongPress: app == null ? null : () => showAppMenu(context, app, () => _launch(app)),
        child: row,
      );
    } else if (m.text.isNotEmpty && m.img == null) {
      // Any other message: long-press copies its text
      row = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () {
          prefs.heavy();
          Clipboard.setData(ClipboardData(text: m.text));
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
        },
        child: row,
      );
    }
    final canReply = !m.me && !m.error && !m.talk && (m.media || m.canReply || !m.isNotif);
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
    // Bots you use in Vibe already talk here directly; skip the Telegram app's copy of their messages
    if (Telegram.i.ready && Telegram.appPackages.contains(pkg)) {
      final t = (n['title'] ?? '').toString();
      if (Telegram.i.chats.values.any((c) => Telegram.i.isBot(c) && '${c['title']}' == t)) return;
    }
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
    // Already playing when Vibe (re)started: skip if this song is already in the recent timeline
    if (n['initial'] == true &&
        chat.msgs.reversed.take(30).any((x) => x.media && x.pkg == pkg && x.text.contains('"$title"'))) {
      return;
    }
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
                decoration: big ? BoxDecoration(color: VC.blurple, shape: BoxShape.circle) : null,
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
    if (m.nkey?.startsWith('tg:') == true) {
      _openTelegramChat(int.parse(m.nkey!.split(':')[1]));
      return;
    }
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
      // Replying to a Vibe answer continues THAT conversation, however long ago it was
      final t = to.thread ?? 't${to.ts}';
      if (to.thread == null) chat.replace(to, to.inThread(t));
      _tagLastMine(t);
      final r = Brain.handle(text, _apps);
      if (r.sure && r.act != Act.none) {
        await _doLocal(r);
      } else if (Gemini.enabled || _nano == 'available') {
        await _askGemini(text, thread: t);
      } else {
        await _doLocal(r);
      }
      return;
    }
    if (to.nkey?.startsWith('tg:') == true) {
      final parts = to.nkey!.split(':');
      final r = await Telegram.i.sendText(int.parse(parts[1]), text,
          replyTo: parts.length > 2 ? int.tryParse(parts[2]) : null);
      if (Telegram.isError(r)) _say('Telegram didn\'t send it: ${r['message']}', error: true);
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
/// App tray laid out like Vibe's home: category rail on the left, search + app list in the middle,
/// and the floating "you" card at the bottom.
class _AppDrawer extends StatefulWidget {
  final List<AppEntry> apps;
  final bool loaded;
  final String status;
  final void Function(AppEntry) onLaunch;
  final VoidCallback onSearch, onPlayStore, onMissed, onSettings;
  final VoidCallback? onTelegram, onDialer;
  const _AppDrawer({
    this.onTelegram,
    this.onDialer,
    required this.apps,
    required this.loaded,
    required this.status,
    required this.onLaunch,
    required this.onSearch,
    required this.onPlayStore,
    required this.onMissed,
    required this.onSettings,
  });
  @override
  State<_AppDrawer> createState() => _AppDrawerState();
}

/// Android's app categories (ApplicationInfo.category), plus "Recent" (-2) and everything else (-1).
const _cats = <(int, String, IconData)>[
  (-2, 'Recent', Icons.history_rounded),
  (4, 'Social', Icons.forum_rounded),
  (1, 'Music & audio', Icons.headphones_rounded),
  (2, 'Video', Icons.movie_rounded),
  (3, 'Photos', Icons.photo_rounded),
  (0, 'Games', Icons.sports_esports_rounded),
  (5, 'News', Icons.newspaper_rounded),
  (6, 'Maps', Icons.map_rounded),
  (7, 'Productivity', Icons.work_rounded),
  (8, 'Accessibility', Icons.accessibility_new_rounded),
  (-1, 'Other', Icons.apps_rounded),
];

class _AppDrawerState extends State<_AppDrawer> {
  final _filter = TextEditingController();
  int? _cat; // null = all apps

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  int _catOf(AppEntry a) => _cats.any((e) => e.$1 == a.category && e.$1 >= 0) ? a.category : -1;

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final q = _filter.text.trim().toLowerCase();
    final shown = widget.apps.where((a) => !prefs.hidden.contains(a.pkg)).toList();
    int byName(AppEntry a, AppEntry b) => a.label.toLowerCase().compareTo(b.label.toLowerCase());
    int byRecent(AppEntry a, AppEntry b) {
      final d = (prefs.lastUsed[b.pkg] ?? 0).compareTo(prefs.lastUsed[a.pkg] ?? 0);
      return d != 0 ? d : byName(a, b);
    }

    // Rail: only categories that have apps
    final cats = _cats.where((e) {
      if (e.$1 == -2) return shown.any((a) => prefs.lastUsed.containsKey(a.pkg));
      return shown.any((a) => _catOf(a) == e.$1);
    }).toList();
    if (_cat != null && !cats.any((e) => e.$1 == _cat)) _cat = null;

    var list = shown.where((a) {
      if (q.isNotEmpty && !a.label.toLowerCase().contains(q)) return false;
      if (_cat == null || q.isNotEmpty) return true;
      if (_cat == -2) return prefs.lastUsed.containsKey(a.pkg);
      return _catOf(a) == _cat;
    }).toList();
    if (_cat == -2) {
      list.sort(byRecent);
      list = list.take(20).toList();
    } else {
      list.sort(prefs.sort == SortMode.az || q.isNotEmpty ? byName : byRecent);
    }
    final title = q.isNotEmpty
        ? 'RESULTS'
        : _cat == null
            ? 'ALL APPS'
            : _cats.firstWhere((e) => e.$1 == _cat).$2.toUpperCase();

    return ColoredBox(
      color: c.rail,
      child: Stack(children: [
        Row(children: [
          _rail(c, cats),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(24)),
              child: Material(
                color: c.chat,
                child: SafeArea(
                  bottom: false,
                  left: false,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: TextField(
                        controller: _filter,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (list.isNotEmpty) widget.onLaunch(list.first);
                        },
                        textInputAction: TextInputAction.go,
                        style: TextStyle(color: c.text, fontSize: 16),
                        decoration: InputDecoration(
                          hintText: 'Find or open an app',
                          hintStyle: TextStyle(color: c.faint),
                          prefixIcon: Icon(Icons.search, color: c.muted),
                          filled: true,
                          fillColor: c.rail,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: !widget.loaded
                          ? Center(child: CircularProgressIndicator(color: VC.blurple))
                          : Builder(builder: (_) {
                              final top = [
                                if (q.isEmpty)
                                  _navTile(c, Icons.manage_search_rounded, 'Search everything', widget.onSearch),
                                if (q.isEmpty && widget.onDialer != null)
                                  _navTile(c, Icons.dialpad_rounded, 'Dialer', widget.onDialer!),
                                if (q.isEmpty && widget.onTelegram != null)
                                  _navTile(c, Icons.send_rounded, 'Telegram chats', widget.onTelegram!),
                                _section(c, '$title — ${list.length}', widget.onPlayStore),
                              ];
                              return ListView.builder(
                                padding: const EdgeInsets.only(bottom: 110),
                                itemCount: top.length + list.length,
                                itemBuilder: (_, i) {
                                  if (i < top.length) return top[i];
                                  final a = list[i - top.length];
                                  return Stagger(
                                    key: ValueKey('app_${_cat}_${a.pkg}'),
                                    index: i - top.length,
                                    dy: 12,
                                    child: Pressable(scale: 0.97, child: _appTile(c, a)),
                                  );
                                },
                              );
                            }),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
        Positioned(left: 0, right: 0, bottom: 0, child: _userBar(c)),
      ]),
    );
  }

  /// Far-left rail: you on top, then one round button per category, "+" for the Play Store.
  Widget _rail(VC c, List<(int, String, IconData)> cats) {
    Widget item(bool active, Widget child, VoidCallback onTap, String tip) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Tooltip(
            message: tip,
            child: Stack(alignment: Alignment.center, children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    width: 4,
                    height: active ? 30 : 0,
                    decoration: BoxDecoration(
                      color: c.text,
                      borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(4), bottomRight: Radius.circular(4)),
                    ),
                  ),
                ),
              ),
              Pressable(
                child: GestureDetector(
                  onTap: () {
                    prefs.tap();
                    onTap();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(active ? 19 : 28),
                      border: Border.all(width: 2, color: active ? VC.blurple : Colors.transparent),
                    ),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: active ? 15.0 : 23.0),
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      builder: (_, r, __) => ClipRRect(
                        borderRadius: BorderRadius.circular(r),
                        child: SizedBox(width: 46, height: 46, child: child),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        );

    return SafeArea(
      right: false,
      bottom: false,
      child: SizedBox(
        width: 72,
        child: Column(children: [
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => setState(() {
              _cat = null;
              _filter.clear();
            }),
            child: Avatar(name: prefs.name, size: 48, ring: c.rail),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
            child: Divider(height: 1, color: c.divider),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.only(bottom: 110), children: [
              for (final e in cats)
                item(
                  _cat == e.$1,
                  ColoredBox(
                    color: _cat == e.$1 ? VC.blurple : c.pane,
                    child: Icon(e.$3, size: 22, color: _cat == e.$1 ? Colors.white : c.muted),
                  ),
                  () => setState(() {
                    _cat = _cat == e.$1 ? null : e.$1;
                    _filter.clear();
                  }),
                  e.$2,
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Material(
                    color: c.input,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: Icon(Icons.add, color: VC.blurple),
                      tooltip: 'Get apps',
                      onPressed: widget.onPlayStore,
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _navTile(VC c, IconData icon, String label, VoidCallback onTap) => ListTile(
        dense: true,
        leading: Icon(icon, color: c.muted),
        title: Text(label, style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
        onTap: onTap,
      );

  Widget _section(VC c, String text, VoidCallback onAdd) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: c.muted)),
          ),
          IconButton(icon: Icon(Icons.add, color: c.muted), tooltip: 'Get apps', onPressed: onAdd),
        ]),
      );

  Widget _appTile(VC c, AppEntry a) {
    final seen = ago(prefs.lastUsed[a.pkg]);
    final cat = _cats.firstWhere((e) => e.$1 == _catOf(a));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.hardEdge,
        child: ListTile(
          onTap: () => widget.onLaunch(a),
          onLongPress: () => showAppMenu(context, a, () => widget.onLaunch(a)),
          contentPadding: const EdgeInsets.only(left: 10, right: 0),
          leading: appIcon(a, 42),
          title: Text(a.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
          subtitle: Row(children: [
            Icon(seen.isEmpty ? cat.$3 : Icons.schedule_rounded, size: 12, color: c.muted),
            const SizedBox(width: 4),
            Expanded(
              child: Text(seen.isEmpty ? (cat.$1 == -1 ? 'App' : cat.$2) : seen,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
            ),
          ]),
        ),
      ),
    );
  }

  /// Floating card at the bottom: big avatar over a pill with your name, status, bell and gear.
  Widget _userBar(VC c) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: SizedBox(
            height: 76,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(
                left: 34,
                right: 0,
                top: 8,
                bottom: 8,
                child: Material(
                  color: c.pane,
                  elevation: 6,
                  shadowColor: Colors.black,
                  shape: const StadiumBorder(),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 50, right: 8),
                    child: Row(children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(prefs.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 16)),
                            Text(widget.status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, color: c.muted)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.notifications),
                        color: c.muted,
                        tooltip: 'What did I miss?',
                        onPressed: widget.onMissed,
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings),
                        color: c.muted,
                        tooltip: 'Vibe settings',
                        onPressed: widget.onSettings,
                      ),
                    ]),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: c.chat),
                  child: Avatar(name: prefs.name, size: 64, ring: c.chat),
                ),
              ),
            ]),
          ),
        ),
      );
}

/// "Vibe is typing…" row with bouncing dots.
class _TypingRowHolder extends StatelessWidget {
  final String label;
  const _TypingRowHolder({this.label = 'Vibe is typing…'});
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
        Text(label, style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
