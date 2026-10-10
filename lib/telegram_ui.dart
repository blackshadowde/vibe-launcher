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
// Chat list
// =====================================================================================
class TelegramChatsPage extends StatefulWidget {
  const TelegramChatsPage({super.key});
  @override
  State<TelegramChatsPage> createState() => _TelegramChatsPageState();
}

class _TelegramChatsPageState extends State<TelegramChatsPage> {
  final _filter = TextEditingController();

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

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final tg = Telegram.i;
    final q = _filter.text.trim().toLowerCase();
    final list = tg.sortedChats().where((ch) => q.isEmpty || '${ch['title']}'.toLowerCase().contains(q)).toList();
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              style: _t(c, size: 16),
              decoration: _field(c, 'Find a chat').copyWith(prefixIcon: Icon(Icons.search, color: c.muted)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Row(children: [
              Text('CHATS — ${list.length}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: c.muted)),
            ]),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(child: tg.ready ? Text('No chats yet', style: _t(c, color: c.faint)) : CircularProgressIndicator(color: VC.blurple))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final ch = list[i];
                      final last = ch['last_message'] as Map?;
                      final unread = (ch['unread_count'] as num?)?.toInt() ?? 0;
                      final t = last == null ? null : DateTime.fromMillisecondsSinceEpoch(((last['date'] as num?) ?? 0).toInt() * 1000);
                      final who = last == null || Telegram.isPrivate(ch) ? '' : '${tg.senderName(last)}: ';
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
                              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => TelegramChatPage(chatId: Telegram.idOf(ch)))),
                              leading: Avatar(name: '${ch['title']}', size: 42, dot: false),
                              title: Row(children: [
                                if (Telegram.isChannel(ch))
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(Icons.campaign_rounded, size: 15, color: c.muted),
                                  ),
                                Expanded(
                                  child: Text('${ch['title']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _t(c, w: unread > 0 ? FontWeight.w800 : FontWeight.w600)),
                                ),
                                if (t != null) Text(sameDay(t, DateTime.now()) ? clock(t) : dayLabel(t), style: _t(c, size: 11, color: c.faint)),
                              ]),
                              subtitle: Row(children: [
                                Expanded(
                                  child: Text(last == null ? '' : '$who${Telegram.textOf(last)}',
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(c, size: 13, color: c.muted)),
                                ),
                                if (unread > 0)
                                  Container(
                                    margin: const EdgeInsets.only(left: 6),
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    constraints: const BoxConstraints(minWidth: 20),
                                    decoration: BoxDecoration(color: VC.red, borderRadius: BorderRadius.circular(10)),
                                    child: Text('$unread',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                                  ),
                              ]),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

// =====================================================================================
// One chat
// =====================================================================================
class TelegramChatPage extends StatefulWidget {
  final int chatId;
  const TelegramChatPage({super.key, required this.chatId});
  @override
  State<TelegramChatPage> createState() => _TelegramChatPageState();
}

class _TelegramChatPageState extends State<TelegramChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<Map> _msgs = []; // newest first
  bool _loading = true;
  bool _more = true;
  Map? _replyTo;

  @override
  void initState() {
    super.initState();
    Telegram.i.openChat(widget.chatId, _onLive);
    _load();
    _scroll.addListener(() {
      if (_more && !_loading && _scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _load(older: true);
    });
  }

  @override
  void dispose() {
    Telegram.i.closeChat(widget.chatId);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool older = false}) async {
    setState(() => _loading = true);
    final from = older && _msgs.isNotEmpty ? Telegram.idOf(_msgs.last) : 0;
    final got = await Telegram.i.history(widget.chatId, fromId: from, want: 40);
    if (!mounted) return;
    final ids = _msgs.map(Telegram.idOf).toSet();
    setState(() {
      _msgs = [..._msgs, ...got.where((m) => !ids.contains(Telegram.idOf(m)))];
      _more = got.isNotEmpty;
      _loading = false;
    });
    if (!older) {
      Telegram.i.markRead(widget.chatId, got.take(20).map(Telegram.idOf).toList());
    }
  }

  void _onLive(Map m) {
    if (!mounted) return;
    setState(() {
      final old = m['_replaces'];
      if (old != null) _msgs.removeWhere((x) => '${x['id']}' == '$old');
      _msgs.removeWhere((x) => Telegram.idOf(x) == Telegram.idOf(m));
      _msgs.insert(0, m);
    });
    if (m['is_outgoing'] != true) Telegram.i.markRead(widget.chatId, [Telegram.idOf(m)]);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    prefs.tap();
    _input.clear();
    final reply = _replyTo;
    setState(() => _replyTo = null);
    final r = await Telegram.i.sendText(widget.chatId, text, replyTo: reply == null ? null : Telegram.idOf(reply));
    if (Telegram.isError(r) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not sent: ${r['message']}')));
    } else if (!Telegram.isError(r)) {
      _onLive(r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final tg = Telegram.i;
    final chat = tg.chats[widget.chatId];
    final channel = chat != null && Telegram.isChannel(chat);
    return Scaffold(
      backgroundColor: c.chat,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            child: Row(children: [
              IconButton(icon: Icon(Icons.arrow_back_rounded, color: c.text), onPressed: () => Navigator.pop(context)),
              Avatar(name: tg.chatTitle(widget.chatId), size: 36, dot: false),
              const SizedBox(width: 10),
              Expanded(
                child: Text(tg.chatTitle(widget.chatId),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(c, size: 17, w: FontWeight.w700)),
              ),
            ]),
          ),
          Divider(height: 1, color: c.divider),
          Expanded(
            child: _msgs.isEmpty && _loading
                ? Center(child: CircularProgressIndicator(color: VC.blurple))
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount: _msgs.length,
                    itemBuilder: (_, i) {
                      final m = _msgs[i];
                      final older = i + 1 < _msgs.length ? _msgs[i + 1] : null;
                      final t = DateTime.fromMillisecondsSinceEpoch(((m['date'] as num?) ?? 0).toInt() * 1000);
                      final ot = older == null ? null : DateTime.fromMillisecondsSinceEpoch(((older['date'] as num?) ?? 0).toInt() * 1000);
                      final newDay = ot == null || !sameDay(ot, t);
                      final name = tg.senderName(m);
                      final head = newDay || older == null || tg.senderName(older) != name ||
                          t.difference(ot!).inMinutes > 5;
                      final row = _bubble(c, m, name, t, head);
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
                        channel
                            ? row
                            : SwipeReply(
                                onReply: () {
                                  prefs.tap();
                                  setState(() => _replyTo = m);
                                },
                                child: row,
                              ),
                      ]);
                    },
                  ),
          ),
          if (_replyTo != null)
            Container(
              color: c.pane,
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(children: [
                Icon(Icons.reply_rounded, size: 18, color: c.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Replying to ${tg.senderName(_replyTo!)}: ${Telegram.textOf(_replyTo!)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(c, size: 13, color: c.muted)),
                ),
                IconButton(
                    icon: Icon(Icons.close_rounded, size: 18, color: c.muted),
                    onPressed: () => setState(() => _replyTo = null)),
              ]),
            ),
          if (!channel)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    style: _t(c, size: 16),
                    decoration: _field(c, 'Message ${tg.chatTitle(widget.chatId)}')
                        .copyWith(border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: VC.blurple,
                  shape: const CircleBorder(),
                  child: IconButton(icon: const Icon(Icons.send_rounded, color: Colors.white), onPressed: _send),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _bubble(VC c, Map m, String name, DateTime t, bool head) {
    final mine = m['is_outgoing'] == true;
    final text = Text(Telegram.textOf(m), style: _t(c, size: 16).copyWith(height: 1.35));
    if (!head) return Padding(padding: const EdgeInsets.fromLTRB(68, 2, 16, 2), child: text);
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
                    style: TextStyle(
                        color: c.nameColor(mine), shadows: c.nameShadows, fontWeight: FontWeight.w600, fontSize: 16)),
              ),
              const SizedBox(width: 8),
              Text(stamp(t), style: _t(c, size: 12, color: c.faint)),
            ]),
            const SizedBox(height: 2),
            text,
          ]),
        ),
      ]),
    );
  }
}
