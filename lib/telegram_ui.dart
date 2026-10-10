import 'package:flutter/material.dart';
import 'chat.dart';
import 'launcher.dart';
import 'telegram.dart';
import 'theme.dart';
import 'widgets.dart';

TextStyle _t(VC c, {double size = 15, FontWeight w = FontWeight.w400, Color? color}) =>
    TextStyle(color: color ?? c.text, fontSize: size, fontWeight: w);

InputDecoration _field(VC c, String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: c.faint),
      filled: true,
      fillColor: c.rail,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    );

// =====================================================================================
// Log in: API ID & hash → phone → code → (password / email) → done
// =====================================================================================
class TelegramLoginPage extends StatefulWidget {
  const TelegramLoginPage({super.key});
  @override
  State<TelegramLoginPage> createState() => _TelegramLoginPageState();
}

class _TelegramLoginPageState extends State<TelegramLoginPage> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _busy = false;
  String _err = '';

  @override
  void initState() {
    super.initState();
    Telegram.i.addListener(_changed);
    if (Telegram.i.configured) Telegram.i.start();
  }

  @override
  void dispose() {
    Telegram.i.removeListener(_changed);
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  String _lastState = '';
  void _changed() {
    if (!mounted) return;
    if (Telegram.i.state != _lastState) {
      _lastState = Telegram.i.state;
      _a.clear();
      _b.clear();
      _err = '';
      if (Telegram.i.ready) {
        Navigator.of(context).pop(true);
        return;
      }
    }
    setState(() {});
  }

  Future<void> _go(Future<String?> Function() f) async {
    setState(() {
      _busy = true;
      _err = '';
    });
    final e = await f();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _err = e ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final tg = Telegram.i;
    late final String title, sub, hintA;
    String? hintB;
    bool secret = false;
    TextInputType kb = TextInputType.text;
    late final Future<String?> Function() submit;
    Widget? extra;

    if (!tg.configured) {
      title = 'Connect Telegram';
      sub = 'Telegram asks every app for its own ID. It\'s free and takes a minute:\n'
          '1. Open my.telegram.org and log in with your number\n'
          '2. Tap "API development tools" and create an app (any name, platform Android)\n'
          '3. Copy the api_id and api_hash here';
      hintA = 'api_id (numbers)';
      hintB = 'api_hash';
      kb = TextInputType.number;
      extra = TextButton.icon(
        onPressed: () => Native.openUrl('https://my.telegram.org/apps'),
        icon: Icon(Icons.open_in_new_rounded, color: VC.blurple, size: 18),
        label: Text('Open my.telegram.org', style: TextStyle(color: VC.blurple)),
      );
      submit = () async {
        final id = _a.text.trim(), hash = _b.text.trim();
        if (!RegExp(r'^\d{3,12}$').hasMatch(id)) return 'api_id is a number, like 1234567.';
        if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hash)) return 'api_hash is 32 letters and numbers.';
        prefs.setTelegram(id, hash);
        await Telegram.i.start();
        return Telegram.i.error.isEmpty ? null : Telegram.i.error;
      };
    } else {
      switch (tg.state) {
        case 'waitPhone':
          title = 'Your phone number';
          sub = 'The number of your Telegram account, with country code.';
          hintA = '+91 98765 43210';
          kb = TextInputType.phone;
          submit = () => tg.sendPhone(_a.text);
        case 'waitCode':
          title = 'Enter the code';
          sub = tg.codeHint;
          hintA = 'Code';
          kb = TextInputType.number;
          submit = () => tg.sendCode(_a.text);
        case 'waitPassword':
          title = 'Two-step password';
          sub = 'Your account has a cloud password.${tg.passwordHint.isEmpty ? '' : ' Hint: ${tg.passwordHint}'}';
          hintA = 'Password';
          secret = true;
          submit = () => tg.sendPassword(_a.text);
        case 'waitEmail':
          title = 'Login email';
          sub = 'Telegram wants an email address for login codes.';
          hintA = 'you@example.com';
          kb = TextInputType.emailAddress;
          submit = () => tg.sendEmail(_a.text);
        case 'waitEmailCode':
          title = 'Email code';
          sub = 'Enter the code Telegram emailed you.';
          hintA = 'Code';
          kb = TextInputType.number;
          submit = () => tg.sendEmailCode(_a.text);
        case 'waitSignup':
          title = 'No account yet';
          sub = 'This number has no Telegram account. Sign up once in the Telegram app, then log in here.';
          hintA = '';
          submit = () async => null;
        default:
          title = 'Connecting to Telegram…';
          sub = tg.error.isNotEmpty ? tg.error : 'One moment.';
          hintA = '';
          submit = () async => null;
      }
    }
    final showField = hintA.isNotEmpty;

    return Scaffold(
      backgroundColor: c.chat,
      appBar: AppBar(backgroundColor: c.chat, elevation: 0, title: Text('Telegram', style: _t(c, size: 18, w: FontWeight.w600))),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 32), children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: const Color(0xFF2AABEE), borderRadius: BorderRadius.circular(24)),
            child: const Icon(Icons.send_rounded, color: Colors.white, size: 34),
          ),
        ),
        const SizedBox(height: 18),
        Text(title, textAlign: TextAlign.center, style: _t(c, size: 22, w: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(sub, textAlign: tg.configured ? TextAlign.center : TextAlign.start, style: _t(c, size: 14, color: c.muted)),
        if (extra != null) ...[const SizedBox(height: 4), extra],
        const SizedBox(height: 18),
        if (showField)
          TextField(
            controller: _a,
            autofocus: true,
            obscureText: secret,
            keyboardType: kb,
            style: _t(c, size: 16),
            decoration: _field(c, hintA),
            onSubmitted: (_) => _busy ? null : _go(submit),
          ),
        if (hintB != null) ...[
          const SizedBox(height: 10),
          TextField(controller: _b, style: _t(c, size: 16), decoration: _field(c, hintB)),
        ],
        if (_err.isNotEmpty || (tg.error.isNotEmpty && showField)) ...[
          const SizedBox(height: 10),
          Text(_err.isNotEmpty ? _err : tg.error, style: const TextStyle(color: VC.red)),
        ],
        const SizedBox(height: 18),
        if (showField)
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: VC.blurple,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: _busy ? null : () => _go(submit),
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Continue', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          )
        else if (!tg.ready && tg.state != 'waitSignup')
          Center(child: CircularProgressIndicator(color: VC.blurple)),
        const SizedBox(height: 24),
        Text('Your messages stay between your phone and Telegram. Vibe AI never reads them unless you ask it to.',
            textAlign: TextAlign.center, style: _t(c, size: 12, color: c.faint)),
      ]),
    );
  }
}

// =====================================================================================
// A file inside a message: Download → progress → Open
// =====================================================================================
class TgFileTile extends StatelessWidget {
  final TgFile file;
  final String from;
  const TgFileTile({super.key, required this.file, this.from = ''});

  IconData get _icon => switch (file.kind) {
        'video' => Icons.movie_rounded,
        'audio' => Icons.music_note_rounded,
        'voice' => Icons.mic_rounded,
        'photo' => Icons.image_rounded,
        _ => Icons.insert_drive_file_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return ListenableBuilder(
      listenable: Telegram.i,
      builder: (context, _) {
        final d = Telegram.i.downloads[file.id];
        final st = d?['state']?.toString() ?? 'none';
        final size = ((d?['size'] as num?)?.toInt() ?? 0) > 0 ? (d!['size'] as num).toInt() : file.size;
        final done = (d?['done'] as num?)?.toInt() ?? 0;
        final frac = size > 0 ? (done / size).clamp(0.0, 1.0) : null;
        final sub = switch (st) {
          'downloading' => '${TgFile.human(done)} of ${TgFile.human(size)}${frac == null ? '' : ' · ${(frac * 100).toStringAsFixed(0)}%'}',
          'paused' => 'Paused · ${TgFile.human(done)} of ${TgFile.human(size)}',
          'saving' => 'Saving to Download/Vibe Telegram…',
          'done' => 'Saved · ${TgFile.human(size)}',
          'failed' => 'Download failed · tap to retry',
          _ => TgFile.human(size),
        };
        Future<void> tap() async {
          prefs.tap();
          if (st == 'done' && d?['uri'] != null) {
            await Native.openFile('${d!['uri']}', file.mime);
          } else if (st == 'downloading') {
            await Telegram.i.cancel(file.id);
          } else if (st != 'saving') {
            await Telegram.i.download(file, from: from);
          }
        }

        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.divider)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: tap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: const Color(0xFF2AABEE), borderRadius: BorderRadius.circular(10)),
                  child: Icon(_icon, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: _t(c, size: 14.5, w: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(sub, style: _t(c, size: 12, color: st == 'failed' ? VC.red : c.faint)),
                    if (st == 'downloading' || st == 'saving')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                              value: st == 'saving' ? null : frac, minHeight: 4, backgroundColor: c.input, color: VC.blurple),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(width: 8),
                Icon(
                  switch (st) {
                    'done' => Icons.open_in_new_rounded,
                    'downloading' => Icons.close_rounded,
                    'saving' => Icons.hourglass_top_rounded,
                    _ => Icons.download_rounded,
                  },
                  color: st == 'done' ? VC.green : c.muted,
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

// =====================================================================================
// Hub: Channels · Bots · Downloads
// =====================================================================================
class TelegramChatsPage extends StatefulWidget {
  final int tab; // 0 channels, 1 bots, 2 downloads
  const TelegramChatsPage({super.key, this.tab = 0});
  @override
  State<TelegramChatsPage> createState() => _TelegramChatsPageState();
}

class _TelegramChatsPageState extends State<TelegramChatsPage> {
  final _filter = TextEditingController();
  late int _tab = widget.tab;
  List<Map>? _found; // public search results
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    Telegram.i.addListener(_changed);
    if (Telegram.i.ready && Telegram.i.chats.length < 5) Telegram.i.loadChats();
  }

  @override
  void dispose() {
    Telegram.i.removeListener(_changed);
    _filter.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _searchPublic() async {
    final q = _filter.text.trim();
    if (q.length < 3) return;
    setState(() => _searching = true);
    final link = Telegram.linkIn(q);
    List<Map> r;
    if (link != null) {
      final res = await Telegram.i.resolveLink(link);
      r = res?['chat'] is Map ? [res!['chat'] as Map] : [];
    } else {
      r = await Telegram.i.searchPublic(q.replaceFirst('@', ''));
    }
    if (!mounted) return;
    setState(() {
      _found = r;
      _searching = false;
    });
  }

  Widget _chatRow(VC c, Map ch, int i) {
    final tg = Telegram.i;
    final last = ch['last_message'] as Map?;
    final unread = (ch['unread_count'] as num?)?.toInt() ?? 0;
    final bot = tg.isBot(ch);
    final member = tg.isMember(ch);
    final sub = last == null
        ? (bot ? 'Bot' : member ? 'Channel' : 'Not joined')
        : Telegram.textOf(last);
    return Stagger(
      index: i,
      dy: 12,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.hardEdge,
          child: ListTile(
            contentPadding: const EdgeInsets.only(left: 10, right: 10),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => TelegramChatPage(chatId: Telegram.idOf(ch)))),
            leading: Avatar(name: '${ch['title']}', size: 42, dot: false),
            title: Row(children: [
              Icon(bot ? Icons.smart_toy_rounded : Icons.campaign_rounded, size: 15, color: c.muted),
              const SizedBox(width: 4),
              Expanded(
                child: Text('${ch['title']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(c, w: unread > 0 ? FontWeight.w800 : FontWeight.w600)),
              ),
            ]),
            subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(c, size: 13, color: c.muted)),
            trailing: unread > 0
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 20),
                    decoration: BoxDecoration(color: VC.red, borderRadius: BorderRadius.circular(10)),
                    child: Text('$unread',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final tg = Telegram.i;
    final q = _filter.text.trim().toLowerCase();
    Widget tab(int i, String label, IconData icon) => Expanded(
          child: InkWell(
            onTap: () => setState(() {
              _tab = i;
              _found = null;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: _tab == i ? VC.blurple : Colors.transparent, width: 2))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 18, color: _tab == i ? c.text : c.faint),
                const SizedBox(width: 6),
                Text(label, style: _t(c, size: 14, w: FontWeight.w600, color: _tab == i ? c.text : c.faint)),
              ]),
            ),
          ),
        );

    Widget body;
    if (_tab == 2) {
      final list = tg.downloadList();
      body = list.isEmpty
          ? Center(child: Text('No downloads yet.\nTap a file in a channel or bot chat.', textAlign: TextAlign.center, style: _t(c, color: c.faint)))
          : ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 24), children: [
              for (final d in list)
                TgFileTile(
                  file: TgFile((d['id'] as num).toInt(), '${d['name']}', '${d['mime']}', (d['size'] as num?)?.toInt() ?? 0,
                      '${d['mime']}'.startsWith('video') ? 'video' : '${d['mime']}'.startsWith('audio') ? 'audio' : '${d['mime']}'.startsWith('image') ? 'photo' : 'document'),
                ),
            ]);
    } else if (_found != null) {
      body = ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text('ON TELEGRAM — ${_found!.length}',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: c.muted)),
        ),
        for (var i = 0; i < _found!.length; i++) _chatRow(c, _found![i], i),
        if (_found!.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Text('Nothing found.', textAlign: TextAlign.center, style: _t(c, color: c.faint))),
      ]);
    } else {
      final list = tg.sortedChats(kind: _tab == 0 ? 'channel' : 'bot')
          .where((ch) => q.isEmpty || '${ch['title']}'.toLowerCase().contains(q))
          .toList();
      body = ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: list.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Text('${_tab == 0 ? 'CHANNELS' : 'BOTS'} — ${list.length}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: c.muted)),
            );
          }
          return _chatRow(c, list[i - 1], i - 1);
        },
      );
      if (list.isEmpty && tg.ready) {
        body = Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
                _tab == 0
                    ? 'No channels yet. Search above, or paste a t.me link in Vibe chat.'
                    : 'No bots yet. Search a bot\'s @username above.',
                textAlign: TextAlign.center,
                style: _t(c, color: c.faint)),
          ),
        );
      }
    }

    return Scaffold(
      backgroundColor: c.chat,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
            child: Row(children: [
              IconButton(icon: Icon(Icons.arrow_back_rounded, color: c.text), onPressed: () => Navigator.pop(context)),
              Text('Telegram', style: _t(c, size: 20, w: FontWeight.w800)),
              const Spacer(),
              if (!tg.ready) Text(tg.state == 'off' ? 'Not connected' : 'Connecting…', style: _t(c, size: 13, color: c.faint)),
            ]),
          ),
          if (_tab != 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              child: TextField(
                controller: _filter,
                onChanged: (_) => setState(() => _found = null),
                onSubmitted: (_) => _searchPublic(),
                textInputAction: TextInputAction.search,
                style: _t(c, size: 16),
                decoration: _field(c, 'Find, or search Telegram (@name or t.me link)').copyWith(
                  prefixIcon: Icon(Icons.search, color: c.muted),
                  suffixIcon: _searching
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: VC.blurple)))
                      : IconButton(icon: Icon(Icons.travel_explore_rounded, color: c.muted), onPressed: _searchPublic),
                ),
              ),
            ),
          Row(children: [
            tab(0, 'Channels', Icons.campaign_rounded),
            tab(1, 'Bots', Icons.smart_toy_rounded),
            tab(2, 'Downloads', Icons.download_rounded),
          ]),
          Divider(height: 1, color: c.divider),
          Expanded(child: body),
        ]),
      ),
    );
  }
}

// =====================================================================================
// One channel or bot: posts, files, buttons
// =====================================================================================
class TelegramChatPage extends StatefulWidget {
  final int chatId;
  final String startParam;
  const TelegramChatPage({super.key, required this.chatId, this.startParam = ''});
  @override
  State<TelegramChatPage> createState() => _TelegramChatPageState();
}

class _TelegramChatPageState extends State<TelegramChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<Map> _msgs = []; // newest first
  bool _loading = true;
  bool _more = true;
  String _kind = 'all'; // channel file filter
  String _query = '';
  Map? _keyboard; // a bot's reply keyboard

  Telegram get tg => Telegram.i;
  Map? get chat => tg.chats[widget.chatId];
  bool get bot => chat != null && tg.isBot(chat!);
  bool get channel => chat != null && !bot;
  bool get filtered => _kind != 'all' || _query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    tg.addListener(_changed);
    tg.openChat(widget.chatId, _onLive);
    _load();
    _scroll.addListener(() {
      if (_more && !_loading && _scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _load(older: true);
    });
  }

  @override
  void dispose() {
    tg.removeListener(_changed);
    tg.closeChat(widget.chatId);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool older = false}) async {
    setState(() => _loading = true);
    final from = older && _msgs.isNotEmpty ? Telegram.idOf(_msgs.last) : 0;
    final got = filtered
        ? await tg.searchFiles(widget.chatId, _query, kind: _kind, fromId: from)
        : await tg.history(widget.chatId, fromId: from, want: 40);
    if (!mounted) return;
    final ids = older ? _msgs.map(Telegram.idOf).toSet() : <int>{};
    setState(() {
      _msgs = [if (older) ..._msgs, ...got.where((m) => !ids.contains(Telegram.idOf(m)))];
      _more = got.isNotEmpty;
      _loading = false;
      if (!older) _keyboard = _findKeyboard();
    });
    if (!older && !filtered) tg.markRead(widget.chatId, got.take(20).map(Telegram.idOf).toList());
    if (!older && bot && got.isEmpty) {
      await tg.startBot(widget.chatId, param: widget.startParam);
    } else if (!older && bot && widget.startParam.isNotEmpty) {
      await tg.startBot(widget.chatId, param: widget.startParam);
    }
  }

  Map? _findKeyboard() {
    for (final m in _msgs.take(10)) {
      final rm = m['reply_markup'] as Map?;
      if (m['is_outgoing'] == true || rm == null) continue;
      if (rm['@type'] == 'replyMarkupShowKeyboard') return rm;
      if (rm['@type'] == 'replyMarkupRemoveKeyboard') return null;
    }
    return null;
  }

  void _onLive(Map m) {
    if (!mounted) return;
    setState(() {
      final old = m['_replaces'];
      if (old != null) _msgs.removeWhere((x) => '${x['id']}' == '$old');
      final i = _msgs.indexWhere((x) => Telegram.idOf(x) == Telegram.idOf(m));
      if (i >= 0) {
        _msgs[i] = m; // edited by the bot
      } else if (!filtered) {
        _msgs.insert(0, m);
      }
      final rm = m['reply_markup'] as Map?;
      if (m['is_outgoing'] != true && rm != null) {
        if (rm['@type'] == 'replyMarkupShowKeyboard') _keyboard = rm;
        if (rm['@type'] == 'replyMarkupRemoveKeyboard') _keyboard = null;
      }
    });
    if (m['is_outgoing'] != true) tg.markRead(widget.chatId, [Telegram.idOf(m)]);
  }

  Future<void> _send([String? text]) async {
    final t = (text ?? _input.text).trim();
    if (t.isEmpty) return;
    prefs.tap();
    if (text == null) _input.clear();
    final r = await tg.sendText(widget.chatId, t);
    if (Telegram.isError(r) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not sent: ${r['message']}')));
    } else if (!Telegram.isError(r)) {
      _onLive(r);
    }
  }

  Future<void> _press(Map m, Map b) async {
    prefs.tap();
    final note = await tg.pressButton(m, b);
    if (note != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
    }
  }

  Future<void> _join() async {
    final err = await tg.join(widget.chatId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Joined ${tg.chatTitle(widget.chatId)}')));
  }

  void _setFilter(String kind) {
    setState(() {
      _kind = kind;
      _msgs = [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final member = chat == null || tg.isMember(chat!);
    Widget chip(String kind, String label) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            label: Text(label),
            selected: _kind == kind,
            onSelected: (_) => _setFilter(kind),
            selectedColor: VC.blurple,
            labelStyle: TextStyle(color: _kind == kind ? Colors.white : c.text, fontWeight: FontWeight.w600, fontSize: 13),
            backgroundColor: c.input,
            side: BorderSide.none,
            showCheckmark: false,
          ),
        );

    return Scaffold(
      backgroundColor: c.chat,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
            child: Row(children: [
              IconButton(icon: Icon(Icons.arrow_back_rounded, color: c.text), onPressed: () => Navigator.pop(context)),
              Avatar(name: tg.chatTitle(widget.chatId), size: 36, dot: false),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tg.chatTitle(widget.chatId),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(c, size: 17, w: FontWeight.w700)),
                  Text(bot ? 'Bot' : member ? 'Channel' : 'Not joined', style: _t(c, size: 12, color: c.faint)),
                ]),
              ),
              if (channel && !member)
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: VC.blurple),
                  onPressed: _join,
                  child: const Text('Join'),
                ),
              if (channel && member)
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded, color: c.muted),
                  onSelected: (v) async {
                    if (v == 'leave') {
                      final err = await tg.leave(widget.chatId);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Left the channel')));
                      }
                    }
                  },
                  itemBuilder: (_) => const [PopupMenuItem(value: 'leave', child: Text('Leave channel'))],
                ),
            ]),
          ),
          if (channel) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: TextField(
                style: _t(c, size: 15),
                textInputAction: TextInputAction.search,
                onSubmitted: (v) {
                  _query = v.trim();
                  setState(() => _msgs = []);
                  _load();
                },
                decoration: _field(c, 'Search files in this channel').copyWith(prefixIcon: Icon(Icons.search, color: c.muted)),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                chip('all', 'All'),
                chip('video', 'Videos'),
                chip('audio', 'Music'),
                chip('document', 'Files'),
                chip('photo', 'Photos'),
              ]),
            ),
          ],
          Divider(height: 1, color: c.divider),
          Expanded(
            child: _msgs.isEmpty && _loading
                ? Center(child: CircularProgressIndicator(color: VC.blurple))
                : _msgs.isEmpty
                    ? Center(child: Text(filtered ? 'Nothing found.' : 'No messages yet.', style: _t(c, color: c.faint)))
                    : ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        itemCount: _msgs.length,
                        itemBuilder: (_, i) {
                          final m = _msgs[i];
                          final older = i + 1 < _msgs.length ? _msgs[i + 1] : null;
                          final t = DateTime.fromMillisecondsSinceEpoch(((m['date'] as num?) ?? 0).toInt() * 1000);
                          final ot = older == null
                              ? null
                              : DateTime.fromMillisecondsSinceEpoch(((older['date'] as num?) ?? 0).toInt() * 1000);
                          final newDay = ot == null || !sameDay(ot, t);
                          final name = tg.senderName(m);
                          final head = newDay || ot == null || tg.senderName(older!) != name || t.difference(ot).inMinutes > 5;
                          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            if (newDay)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                                child: Row(children: [
                                  Expanded(child: Divider(color: c.divider, height: 1)),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                    child: Text(dayLabel(t), style: _t(c, size: 12, w: FontWeight.w600, color: c.faint)),
                                  ),
                                  Expanded(child: Divider(color: c.divider, height: 1)),
                                ]),
                              ),
                            _bubble(c, m, name, t, head),
                          ]);
                        },
                      ),
          ),
          if (bot && _keyboard != null)
            Container(
              color: c.pane,
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Column(children: [
                for (final row in List.from(_keyboard!['rows'] as List? ?? const []))
                  Row(children: [
                    for (final b in List<Map>.from(row as List))
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                                foregroundColor: c.text, side: BorderSide(color: c.divider), padding: const EdgeInsets.symmetric(vertical: 10)),
                            onPressed: () => _send('${b['text']}'),
                            child: Text('${b['text']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ),
                  ]),
              ]),
            ),
          if (bot)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    style: _t(c, size: 16),
                    onSubmitted: (_) => _send(),
                    decoration: _field(c, 'Message ${tg.chatTitle(widget.chatId)}')
                        .copyWith(border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: VC.blurple,
                  shape: const CircleBorder(),
                  child: IconButton(icon: const Icon(Icons.send_rounded, color: Colors.white), onPressed: () => _send()),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _bubble(VC c, Map m, String name, DateTime t, bool head) {
    final mine = m['is_outgoing'] == true;
    final file = TgFile.of(m);
    final caption = file == null ? Telegram.textOf(m) : (((m['content'] as Map?)?['caption'] as Map?)?['text'] ?? '').toString();
    final markup = m['reply_markup'] as Map?;
    final inline = markup?['@type'] == 'replyMarkupInlineKeyboard' ? List.from(markup!['rows'] as List? ?? const []) : const [];
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (caption.isNotEmpty) SelectableText(caption, style: _t(c, size: 15.5).copyWith(height: 1.35)),
      if (file != null) TgFileTile(file: file, from: tg.chatTitle(widget.chatId)),
      for (final row in inline)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            for (final b in List<Map>.from(row as List))
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Material(
                    color: c.input,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _press(m, b),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
                        child: Text('${b['text']}',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: _t(c, size: 13.5, w: FontWeight.w600)),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
    ]);
    if (!head) return Padding(padding: const EdgeInsets.fromLTRB(68, 3, 16, 3), child: body);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Avatar(name: mine ? prefs.name : name, size: 40, dot: false),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(mine ? prefs.name : name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.nameColor(mine), shadows: c.nameShadows, fontWeight: FontWeight.w600, fontSize: 16)),
              ),
              const SizedBox(width: 8),
              Text(stamp(t), style: _t(c, size: 12, color: c.faint)),
            ]),
            const SizedBox(height: 2),
            body,
          ]),
        ),
      ]),
    );
  }
}
