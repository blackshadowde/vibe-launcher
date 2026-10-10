import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'chat.dart';
import 'gemini.dart';
import 'launcher.dart';
import 'main.dart';
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  List<AppEntry> _apps = [];
  bool _isDefault = true;
  bool _loaded = false;
  bool _thinking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.onHomePressed = _goHome;
    chat.load();
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
    final list = await Native.apps();
    final def = await Native.isDefault();
    if (!mounted) return;
    setState(() {
      _apps = list;
      _isDefault = def;
      _loaded = true;
    });
  }

  void _goHome() {
    navKey.currentState?.popUntil((r) => r.isFirst);
    _scaffold.currentState?.closeDrawer();
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
    if (text.isEmpty) return;
    _input.clear();
    prefs.tap();
    chat.add(Msg(true, text));
    _toBottom();

    final r = Brain.handle(text, _apps);
    if (!r.sure && Gemini.enabled) {
      await _askGemini(text);
    } else {
      await Future.delayed(const Duration(milliseconds: 250));
      await _doLocal(r);
    }
  }

  void _say(String text, {List<String> apps = const [], List<Map> links = const [], bool error = false}) {
    chat.add(Msg(false, text, apps: apps, links: links, error: error));
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
      default:
        break;
    }
  }

  void _openDrawer() {
    _focus.unfocus();
    _scaffold.currentState?.openDrawer();
  }

  void _openLauncherSettings() {
    _focus.unfocus();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  // ---------- Gemini ----------
  Future<void> _askGemini(String question) async {
    setState(() => _thinking = true);
    _toBottom();
    try {
      final res = await Gemini.ask(chat.msgs, _apps);
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
      case 'clear_chat':
        chat.clear();
        _say('Chat cleared.');
      default:
        _say(preface.isEmpty ? 'I can\'t do that yet.' : preface);
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
            if (_scaffold.currentState?.isDrawerOpen == true) {
              _scaffold.currentState!.closeDrawer();
            } else {
              _goHome();
            }
          },
          child: Scaffold(
            key: _scaffold,
            backgroundColor: c.chat,
            drawerEdgeDragWidth: 40,
            drawer: _AppDrawer(apps: _apps, loaded: _loaded, onLaunch: (a) {
              _scaffold.currentState?.closeDrawer();
              _launch(a);
            }),
            body: SafeArea(
              child: Column(children: [
                _header(c),
                if (!_isDefault && _loaded) _defaultBanner(),
                Expanded(child: _timeline(c)),
                _inputBar(c),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- top bar: you + settings ----------
  Widget _header(VC c) => Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        decoration: BoxDecoration(
          color: c.chat,
          border: Border(bottom: BorderSide(color: c.divider, width: 0.5)),
        ),
        child: Row(children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () { prefs.tap(); showProfileSheet(context); },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Row(children: [
                  Avatar(name: prefs.name, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(prefs.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.text, fontWeight: FontWeight.w800, fontSize: 18)),
                      Text('Online', style: TextStyle(color: c.muted, fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          IconButton(
            tooltip: 'All apps',
            icon: Icon(Icons.apps_rounded, color: c.muted),
            onPressed: () { prefs.tap(); _focus.unfocus(); _scaffold.currentState?.openDrawer(); },
          ),
          // Tap = phone settings, long-press = launcher settings
          GestureDetector(
            onTap: () { prefs.tap(); Native.openSettings(); },
            onLongPress: () {
              prefs.heavy();
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
            },
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(Icons.settings_rounded, color: c.muted, size: 24),
            ),
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
        itemBuilder: (_, idx) {
          if (_thinking && idx == 0) return _typingRow(c);
          final i = _thinking ? idx - 1 : idx;
          final m = msgs[n - 1 - i];
          final older = n - 2 - i >= 0 ? msgs[n - 2 - i] : null;
          final t = DateTime.fromMillisecondsSinceEpoch(m.ts);
          final ot = older == null ? null : DateTime.fromMillisecondsSinceEpoch(older.ts);
          final newDay = ot == null || !sameDay(ot, t);
          final head = newDay || older!.me != m.me || m.ts - older.ts > 5 * 60 * 1000;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (newDay) _dayDivider(c, t),
            _message(c, m, t, head),
          ]);
        },
      ),
    );
  }

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

  Widget _message(VC c, Msg m, DateTime t, bool head) {
    final body = <Widget>[
      if (m.text.isNotEmpty) richText(m.text, c, error: m.error),
      if (m.links.isNotEmpty) linkChips(m.links, c),
      for (final p in m.apps)
        if (_byPkg(p) case final a?)
          AppCard(app: a, onOpen: () => _launch(a), onLongPress: () => showAppMenu(context, a, () => _launch(a))),
    ];
    if (!head) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(68, 2, 16, 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: body),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        m.me
            ? Avatar(name: prefs.name, size: 40, dot: false)
            : Builder(
                builder: (ctx) => GestureDetector(
                  onLongPress: () => _quickApps(ctx),
                  child: const BotAvatar(size: 40),
                ),
              ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(m.me ? prefs.name : 'Vibe',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              if (!m.me) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: VC.blurple, borderRadius: BorderRadius.circular(4)),
                  child: const Text('APP',
                      style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                ),
              ],
              const SizedBox(width: 8),
              Text(stamp(t), style: TextStyle(color: c.faint, fontSize: 12)),
            ]),
            const SizedBox(height: 2),
            ...body,
          ]),
        ),
      ]),
    );
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
    final typing = _input.text.trim().isNotEmpty;
    return Padding(
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
                  onTap: () { prefs.tap(); _focus.unfocus(); _scaffold.currentState?.openDrawer(); },
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
                    hintText: 'Message Vibe',
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
    return Drawer(
      backgroundColor: c.pane,
      width: MediaQuery.of(context).size.width * 0.86,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(16))),
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
                    itemBuilder: (_, i) => AppRow(
                      app: list[i],
                      onTap: () => widget.onLaunch(list[i]),
                      onLongPress: () => showAppMenu(context, list[i], () => widget.onLaunch(list[i])),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
