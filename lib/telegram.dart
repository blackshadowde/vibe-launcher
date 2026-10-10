import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:handy_tdlib_next/handy_tdlib_next.dart' show TdPlugin;
import 'launcher.dart';

/// Telegram inside Vibe (TDLib): join channels, use download bots, and save their files.
/// Personal chats stay in the Telegram app. Your API ID / hash stay encrypted on this phone.
class Telegram extends ChangeNotifier {
  Telegram._();
  static final Telegram i = Telegram._();

  /// Telegram app packages, so their notifications aren't shown twice once you're logged in here.
  static const appPackages = {
    'org.telegram.messenger',
    'org.telegram.messenger.web',
    'org.telegram.plus',
    'org.thunderdog.challegram',
    'nekox.messenger',
    'tw.nekomimi.nekogram',
  };

  int? _client;
  bool _starting = false;
  Isolate? _loop;
  ReceivePort? _port;
  int _seq = 0;
  final _pending = <int, Completer<Map>>{};

  /// waitParams / waitPhone / waitCode / waitPassword / waitEmail / waitEmailCode / waitSignup / ready / closed / off
  String state = 'off';
  String codeHint = ''; // "Code sent to your Telegram app" etc.
  String passwordHint = '';
  String error = '';
  int? myId;

  final chats = <int, Map>{};
  final users = <int, Map>{};
  final supergroups = <int, Map>{};

  /// File downloads by TDLib file id: name, mime, size, done, state (downloading / saving / done / failed / paused), uri.
  final downloads = <int, Map>{};

  /// A download finished and was saved to Download/Vibe Telegram.
  void Function(Map item)? onDownloaded;
  int _lastTick = 0;
  int? openChatId; // chat open on screen right now (its messages don't pile up in the timeline)

  /// New incoming message for the home timeline.
  void Function(Map msg)? onIncoming;

  /// Live messages for whichever chat screen is open.
  final _chatListeners = <int, void Function(Map msg)>{};

  bool get ready => state == 'ready';
  bool get configured => prefs.tgApiId.isNotEmpty && prefs.tgApiHash.isNotEmpty;

  // ---------------- start / stop ----------------
  Future<void> start() async {
    if (_client != null || _starting || !configured) return;
    _starting = true;
    error = '';
    try {
      await TdPlugin.initialize();
      try {
        TdPlugin.instance.tdExecute(jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1}));
      } catch (_) {}
      _port = ReceivePort();
      _port!.listen(_onRaw);
      _loop = await Isolate.spawn(_receiveLoop, _port!.sendPort);
      _client = TdPlugin.instance.tdCreateClientId();
      // The first request wakes the client up; then TDLib reports its login state
      _send({'@type': 'getOption', 'name': 'version'});
    } catch (e) {
      error = 'Telegram couldn\'t start: $e';
      state = 'off';
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  static Future<void> _receiveLoop(SendPort out) async {
    await TdPlugin.initialize();
    while (true) {
      final r = TdPlugin.instance.tdReceive(1.0);
      if (r != null) out.send(r);
      await Future<void>.delayed(Duration.zero);
    }
  }

  void _send(Map req) {
    final c = _client;
    if (c == null) return;
    TdPlugin.instance.tdSend(c, jsonEncode(req));
  }

  /// Sends a request and waits for its answer. Errors come back as {'@type': 'error', ...}.
  Future<Map> call(Map req, {Duration timeout = const Duration(seconds: 30)}) {
    if (_client == null) return Future.value({'@type': 'error', 'message': 'Telegram isn\'t running'});
    final id = ++_seq;
    final done = Completer<Map>();
    _pending[id] = done;
    _send({...req, '@extra': id});
    return done.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      return {'@type': 'error', 'message': 'Telegram took too long'};
    });
  }

  static bool isError(Map r) => r['@type'] == 'error';

  void _onRaw(dynamic raw) {
    if (raw is! String) return;
    Map j;
    try {
      j = jsonDecode(raw) as Map;
    } catch (_) {
      return;
    }
    if (_client != null && j['@client_id'] != null && j['@client_id'] != _client) return;
    final extra = j['@extra'];
    if (extra is int && _pending.containsKey(extra)) {
      _pending.remove(extra)!.complete(j);
      return;
    }
    try {
      _onUpdate(j);
    } catch (e, st) {
      noteError(e, st);
    }
  }

  // ---------------- updates ----------------
  void _onUpdate(Map u) {
    switch (u['@type']) {
      case 'updateAuthorizationState':
        _onAuth(u['authorization_state'] as Map);
      case 'updateUser':
        final user = u['user'] as Map;
        users[(user['id'] as num).toInt()] = user;
      case 'updateNewChat':
        final c = u['chat'] as Map;
        chats[(c['id'] as num).toInt()] = Map.of(c);
        notifyListeners();
      case 'updateChatTitle':
        chats[_int(u['chat_id'])]?['title'] = u['title'];
        notifyListeners();
      case 'updateChatLastMessage':
        final c = chats[_int(u['chat_id'])];
        if (c != null) {
          c['last_message'] = u['last_message'];
          notifyListeners();
        }
      case 'updateChatReadInbox':
        chats[_int(u['chat_id'])]?['unread_count'] = u['unread_count'];
        notifyListeners();
      case 'updateChatNotificationSettings':
        chats[_int(u['chat_id'])]?['notification_settings'] = u['notification_settings'];
      case 'updateSupergroup':
        final sg = u['supergroup'] as Map;
        supergroups[_int(sg['id'])] = sg;
        notifyListeners();
      case 'updateFile':
        _onFile(u['file'] as Map);
      case 'updateMessageContent':
      case 'updateMessageEdited':
        // Bots often edit their message (new buttons, a file appears): reload it for the open screen
        final chatId = _int(u['chat_id']);
        final l = _chatListeners[chatId];
        if (l != null) {
          call({'@type': 'getMessage', 'chat_id': chatId, 'message_id': u['message_id']}).then((m) {
            if (!isError(m)) l(m);
          });
        }
      case 'updateNewMessage':
        _onNewMessage(u['message'] as Map);
      case 'updateMessageSendSucceeded':
        final m = u['message'] as Map;
        _chatListeners[_int(m['chat_id'])]?.call({...m, '_replaces': u['old_message_id']});
    }
  }

  void _onNewMessage(Map m) {
    final chatId = _int(m['chat_id']);
    final c = chats[chatId];
    if (c != null) {
      c['last_message'] = m;
      notifyListeners();
    }
    _chatListeners[chatId]?.call(m);
    if (m['is_outgoing'] == true || openChatId == chatId) return;
    // Only download bots talk in the timeline; channels and personal chats stay quiet
    if (c == null || !isBot(c)) return;
    onIncoming?.call(m);
  }

  void _onAuth(Map s) {
    error = '';
    switch (s['@type']) {
      case 'authorizationStateWaitTdlibParameters':
        state = 'waitParams';
        _setParams();
      case 'authorizationStateWaitPhoneNumber':
        state = 'waitPhone';
      case 'authorizationStateWaitCode':
        state = 'waitCode';
        final info = s['code_info'] as Map?;
        final t = (info?['type'] as Map?)?['@type']?.toString() ?? '';
        codeHint = t.contains('TelegramMessage')
            ? 'Telegram sent a code to your Telegram app on another device.'
            : t.contains('Sms')
                ? 'Telegram sent the code by SMS.'
                : t.contains('Call')
                    ? 'Telegram will call you with the code.'
                    : 'Enter the code Telegram sent you.';
      case 'authorizationStateWaitPassword':
        state = 'waitPassword';
        passwordHint = (s['password_hint'] ?? '').toString();
      case 'authorizationStateWaitEmailAddress':
        state = 'waitEmail';
      case 'authorizationStateWaitEmailCode':
        state = 'waitEmailCode';
      case 'authorizationStateWaitRegistration':
        state = 'waitSignup';
      case 'authorizationStateReady':
        state = 'ready';
        _afterLogin();
      case 'authorizationStateLoggingOut':
      case 'authorizationStateClosing':
        state = 'closing';
      case 'authorizationStateClosed':
        state = 'closed';
        _client = null;
        _loop?.kill(priority: Isolate.immediate);
        _loop = null;
        _port?.close();
        _port = null;
        chats.clear();
        users.clear();
    }
    notifyListeners();
  }

  Future<void> _setParams() async {
    final dir = await Native.filesDir();
    final r = await call({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': '$dir/tdlib',
      'files_directory': '$dir/tdlib/files',
      'database_encryption_key': '',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': int.tryParse(prefs.tgApiId.trim()) ?? 0,
      'api_hash': prefs.tgApiHash.trim(),
      'system_language_code': 'en',
      'device_model': 'Vibe Launcher',
      'system_version': 'Android',
      'application_version': vibeVersion,
    });
    if (isError(r)) {
      error = _nice(r);
      notifyListeners();
    }
  }

  Future<void> _afterLogin() async {
    final me = await call({'@type': 'getMe'});
    if (!isError(me)) myId = _int(me['id']);
    _loadDone();
    await loadChats();
  }

  // ---------------- downloads ----------------
  void _loadDone() {
    try {
      final raw = prefs.sp.getString('tgDownloads');
      if (raw == null) return;
      for (final e in (jsonDecode(raw) as List)) {
        final m = Map.of(e as Map);
        downloads.putIfAbsent(_int(m['id']), () => m);
      }
    } catch (_) {}
  }

  void _saveDone() {
    final done = downloads.values.where((d) => d['state'] == 'done').toList()
      ..sort((a, b) => _int(b['ts']).compareTo(_int(a['ts'])));
    prefs.sp.setString('tgDownloads', jsonEncode(done.take(150).toList()));
  }

  /// Finished and in-progress downloads, newest first.
  List<Map> downloadList() {
    final l = downloads.values.toList()..sort((a, b) => _int(b['ts']).compareTo(_int(a['ts'])));
    return l;
  }

  Future<void> download(TgFile f, {String from = ''}) async {
    final d = downloads[f.id];
    if (d != null && (d['state'] == 'downloading' || d['state'] == 'saving' || d['state'] == 'done')) return;
    downloads[f.id] = {
      'id': f.id,
      'name': f.name,
      'mime': f.mime,
      'size': f.size,
      'done': 0,
      'state': 'downloading',
      'from': from,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    notifyListeners();
    final r = await call({'@type': 'downloadFile', 'file_id': f.id, 'priority': 16, 'offset': 0, 'limit': 0, 'synchronous': false});
    if (isError(r)) {
      downloads[f.id]!['state'] = 'failed';
      notifyListeners();
    } else {
      _onFile(r);
    }
  }

  Future<void> cancel(int fileId) async {
    await call({'@type': 'cancelDownloadFile', 'file_id': fileId, 'only_if_pending': false});
    downloads.remove(fileId);
    notifyListeners();
  }

  void _onFile(Map f) {
    final id = _int(f['id']);
    final d = downloads[id];
    if (d == null || d['state'] == 'done' || d['state'] == 'saving') return;
    final local = f['local'] as Map? ?? const {};
    final size = _int(f['size']) > 0 ? _int(f['size']) : _int(f['expected_size']);
    if (size > 0) d['size'] = size;
    d['done'] = _int(local['downloaded_size']);
    if (local['is_downloading_completed'] == true) {
      _finish(id, '${local['path']}');
      return;
    }
    if (local['is_downloading_active'] != true && d['state'] == 'downloading' && _int(local['downloaded_size']) > 0) {
      d['state'] = 'paused';
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTick > 400) {
      _lastTick = now;
      notifyListeners();
    }
  }

  Future<void> _finish(int id, String path) async {
    final d = downloads[id]!;
    d['state'] = 'saving';
    notifyListeners();
    final uri = await Native.saveDownload(path, '${d['name']}', '${d['mime']}');
    if (uri == null) {
      d['state'] = 'failed';
    } else {
      d['state'] = 'done';
      d['uri'] = uri;
      d['ts'] = DateTime.now().millisecondsSinceEpoch;
      // Free Telegram's own copy; the saved file is in Download/Vibe Telegram
      call({'@type': 'deleteFile', 'file_id': id});
      _saveDone();
      onDownloaded?.call(d);
    }
    notifyListeners();
  }

  // ---------------- channels, bots, links ----------------
  /// Is this chat a bot (a private chat with a bot account)?
  bool isBot(Map chat) {
    final t = chat['type'] as Map?;
    if (t?['@type'] != 'chatTypePrivate') return false;
    final u = users[_int(t?['user_id'])];
    return (u?['type'] as Map?)?['@type'] == 'userTypeBot';
  }

  int? botUserId(Map chat) => isBot(chat) ? _int((chat['type'] as Map)['user_id']) : null;

  /// For channels / groups: are you a member?
  bool isMember(Map chat) {
    final t = chat['type'] as Map?;
    if (t?['@type'] != 'chatTypeSupergroup') return true;
    final sg = supergroups[_int(t?['supergroup_id'])];
    final st = (sg?['status'] as Map?)?['@type']?.toString() ?? '';
    return st.isNotEmpty && st != 'chatMemberStatusLeft' && st != 'chatMemberStatusBanned';
  }

  Future<String?> join(int chatId) async {
    final r = await call({'@type': 'joinChat', 'chat_id': chatId});
    return isError(r) ? _nice(r) : null;
  }

  Future<String?> leave(int chatId) async {
    final r = await call({'@type': 'leaveChat', 'chat_id': chatId});
    return isError(r) ? _nice(r) : null;
  }

  Future<Map> startBot(int chatId, {String param = ''}) {
    final c = chats[chatId];
    final bot = c == null ? null : botUserId(c);
    if (bot == null) return sendText(chatId, '/start');
    return call({'@type': 'sendBotStartMessage', 'bot_user_id': bot, 'chat_id': chatId, 'parameter': param});
  }

  /// Presses an inline button under a bot's message. Returns the bot's short answer, if any.
  Future<String?> pressButton(Map msg, Map button) async {
    final t = button['type'] as Map? ?? const {};
    switch (t['@type']) {
      case 'inlineKeyboardButtonTypeCallback':
        final r = await call({
          '@type': 'getCallbackQueryAnswer',
          'chat_id': msg['chat_id'],
          'message_id': msg['id'],
          'payload': {'@type': 'callbackQueryPayloadData', 'data': t['data']},
        }, timeout: const Duration(seconds: 20));
        if (isError(r)) return (r['message'] ?? '').toString().contains('timeout') ? null : _nice(r);
        final text = (r['text'] ?? '').toString();
        final url = (r['url'] ?? '').toString();
        if (url.isNotEmpty) Native.openUrl(url);
        return text.isEmpty ? null : text;
      case 'inlineKeyboardButtonTypeUrl':
      case 'inlineKeyboardButtonTypeLoginUrl':
        final url = (t['url'] ?? '').toString();
        if (url.isNotEmpty) Native.openUrl(url);
        return null;
      default:
        return 'This button only works in the Telegram app.';
    }
  }

  /// Public channels and bots matching [q].
  Future<List<Map>> searchPublic(String q) async {
    final out = <Map>[];
    final r = await call({'@type': 'searchPublicChats', 'query': q.trim()});
    for (final id in (r['chat_ids'] as List? ?? [])) {
      final cid = _int(id);
      final c = chats[cid] ?? await call({'@type': 'getChat', 'chat_id': cid});
      if (!isError(c)) {
        chats[cid] = Map.of(c);
        out.add(chats[cid]!);
      }
    }
    return out;
  }

  /// What a t.me link points to: {'kind': chat / invite / post, ...}. Null if it isn't a Telegram link.
  static RegExpMatch? linkIn(String text) => RegExp(
          r'(?:https?://)?(?:t\.me|telegram\.me|telegram\.dog)/(\+[\w-]+|joinchat/[\w-]+|[A-Za-z][\w]{3,})(?:/(\d+))?(?:\?start=([\w-]+))?',
          caseSensitive: false)
      .firstMatch(text);

  Future<Map?> resolveLink(RegExpMatch m) async {
    final part = m.group(1)!;
    final full = m.group(0)!.startsWith('http') ? m.group(0)! : 'https://${m.group(0)!}';
    if (part.startsWith('+') || part.toLowerCase().startsWith('joinchat/')) {
      final info = await call({'@type': 'checkChatInviteLink', 'invite_link': full});
      if (isError(info)) return {'kind': 'error', 'error': _nice(info)};
      return {'kind': 'invite', 'link': full, 'info': info};
    }
    if (m.group(2) != null) {
      final info = await call({'@type': 'getMessageLinkInfo', 'url': full});
      if (!isError(info) && info['message'] is Map) {
        final msg = info['message'] as Map;
        final c = chats[chatOf(msg)] ?? await call({'@type': 'getChat', 'chat_id': msg['chat_id']});
        if (!isError(c)) chats[_int(c['id'])] = Map.of(c);
        return {'kind': 'post', 'message': msg, 'chat': c};
      }
    }
    final c = await call({'@type': 'searchPublicChat', 'username': part});
    if (isError(c)) return {'kind': 'error', 'error': 'I couldn\'t find @$part on Telegram.'};
    chats[_int(c['id'])] = Map.of(c);
    return {'kind': 'chat', 'chat': c, 'start': m.group(3) ?? ''};
  }

  Future<String?> joinInvite(String link) async {
    final r = await call({'@type': 'joinChatByInviteLink', 'invite_link': link});
    return isError(r) ? _nice(r) : null;
  }

  /// Messages with files in a chat, optionally matching [query]. kind: all / video / audio / document / photo
  Future<List<Map>> searchFiles(int chatId, String query, {String kind = 'all', int fromId = 0}) async {
    final filter = switch (kind) {
      'video' => 'searchMessagesFilterVideo',
      'audio' => 'searchMessagesFilterAudio',
      'document' => 'searchMessagesFilterDocument',
      'photo' => 'searchMessagesFilterPhoto',
      _ => 'searchMessagesFilterEmpty',
    };
    final r = await call({
      '@type': 'searchChatMessages',
      'chat_id': chatId,
      'query': query,
      'from_message_id': fromId,
      'offset': 0,
      'limit': 50,
      'filter': {'@type': filter},
    });
    return List<Map>.from(r['messages'] as List? ?? const []);
  }

  // ---------------- login steps ----------------
  Future<String?> sendPhone(String phone) => _step({
        '@type': 'setAuthenticationPhoneNumber',
        'phone_number': phone.replaceAll(RegExp(r'[^\d+]'), ''),
      });
  Future<String?> sendCode(String code) => _step({'@type': 'checkAuthenticationCode', 'code': code.trim()});
  Future<String?> sendPassword(String pw) => _step({'@type': 'checkAuthenticationPassword', 'password': pw});
  Future<String?> sendEmail(String email) =>
      _step({'@type': 'setAuthenticationEmailAddress', 'email_address': email.trim()});
  Future<String?> sendEmailCode(String code) => _step({
        '@type': 'checkAuthenticationEmailCode',
        'code': {'@type': 'emailAddressAuthenticationCode', 'code': code.trim()},
      });

  /// Null = accepted; otherwise a readable error.
  Future<String?> _step(Map req) async {
    final r = await call(req);
    return isError(r) ? _nice(r) : null;
  }

  Future<void> logOut() async {
    if (_client == null) return;
    await call({'@type': 'logOut'});
  }

  static String _nice(Map e) {
    final m = (e['message'] ?? '').toString();
    if (m.contains('PHONE_CODE_INVALID')) return 'That code is wrong. Check it and try again.';
    if (m.contains('PHONE_CODE_EXPIRED')) return 'That code expired. Go back and send a new one.';
    if (m.contains('PASSWORD_HASH_INVALID')) return 'Wrong password.';
    if (m.contains('PHONE_NUMBER_INVALID')) return 'That phone number isn\'t valid. Include the country code, like +91.';
    if (m.contains('API_ID_INVALID') || m.contains('api_id')) return 'Your API ID or hash is wrong. Check them at my.telegram.org.';
    if (m.contains('FLOOD_WAIT')) return 'Too many tries. Telegram asks you to wait a while.';
    return m.isEmpty ? 'Telegram error' : m;
  }

  // ---------------- chats & messages ----------------
  Future<void> loadChats() async {
    await call({'@type': 'loadChats', 'chat_list': {'@type': 'chatListMain'}, 'limit': 60});
    final r = await call({'@type': 'getChats', 'chat_list': {'@type': 'chatListMain'}, 'limit': 100});
    for (final id in (r['chat_ids'] as List? ?? [])) {
      final cid = _int(id);
      if (!chats.containsKey(cid)) {
        final c = await call({'@type': 'getChat', 'chat_id': cid});
        if (!isError(c)) chats[cid] = Map.of(c);
      }
    }
    notifyListeners();
  }

  /// Channels / bots (kind: 'channel' or 'bot'), newest first.
  List<Map> sortedChats({String kind = 'all'}) {
    final l = chats.values.where((c) {
      if (kind == 'channel') return isChannel(c) || (c['type'] as Map?)?['@type'] == 'chatTypeSupergroup';
      if (kind == 'bot') return isBot(c);
      return isChannel(c) || isBot(c);
    }).toList();
    int date(Map c) => _int((c['last_message'] as Map?)?['date']);
    l.sort((a, b) => date(b).compareTo(date(a)));
    return l;
  }

  Future<List<Map>> history(int chatId, {int fromId = 0, int want = 40}) async {
    final out = <Map>[];
    var from = fromId;
    for (var tries = 0; tries < 4 && out.length < want; tries++) {
      final r = await call({
        '@type': 'getChatHistory',
        'chat_id': chatId,
        'from_message_id': from,
        'offset': 0,
        'limit': want - out.length,
        'only_local': false,
      });
      final list = List<Map>.from(r['messages'] as List? ?? const []);
      if (list.isEmpty) break;
      out.addAll(list);
      from = _int(list.last['id']);
    }
    return out; // newest first
  }

  Future<Map> sendText(int chatId, String text, {int? replyTo}) => call({
        '@type': 'sendMessage',
        'chat_id': chatId,
        if (replyTo != null)
          'reply_to': {'@type': 'inputMessageReplyToMessage', 'message_id': replyTo},
        'input_message_content': {
          '@type': 'inputMessageText',
          'text': {'@type': 'formattedText', 'text': text},
        },
      });

  Future<void> markRead(int chatId, List<int> ids) async {
    if (ids.isEmpty) return;
    await call({'@type': 'viewMessages', 'chat_id': chatId, 'message_ids': ids, 'force_read': true});
  }

  void openChat(int chatId, void Function(Map) onMsg) {
    openChatId = chatId;
    _chatListeners[chatId] = onMsg;
    call({'@type': 'openChat', 'chat_id': chatId});
  }

  void closeChat(int chatId) {
    if (openChatId == chatId) openChatId = null;
    _chatListeners.remove(chatId);
    call({'@type': 'closeChat', 'chat_id': chatId});
  }

  /// Finds a chat by name: your chats first, then Telegram's server (usernames too).
  Future<List<Map>> findChats(String q) async {
    final query = q.trim().replaceFirst(RegExp(r'^@'), '');
    final out = <Map>[];
    final seen = <int>{};
    for (final t in ['searchChats', 'searchChatsOnServer']) {
      final r = await call({'@type': t, 'query': query, 'limit': 6});
      for (final id in (r['chat_ids'] as List? ?? [])) {
        final cid = _int(id);
        if (!seen.add(cid)) continue;
        final c = chats[cid] ?? await call({'@type': 'getChat', 'chat_id': cid});
        if (!isError(c)) {
          chats[cid] = Map.of(c);
          out.add(chats[cid]!);
        }
      }
      if (out.isNotEmpty) break;
    }
    if (out.isEmpty && RegExp(r'^[A-Za-z][A-Za-z0-9_]{3,}$').hasMatch(query)) {
      final c = await call({'@type': 'searchPublicChat', 'username': query});
      if (!isError(c)) {
        chats[_int(c['id'])] = Map.of(c);
        out.add(c);
      }
    }
    return out;
  }

  /// A private chat with whoever has this phone number on Telegram (if their privacy allows it).
  Future<Map?> chatForPhone(String phone) async {
    final u = await call({'@type': 'searchUserByPhoneNumber', 'phone_number': phone.replaceAll(RegExp(r'[^\d+]'), '')});
    if (isError(u)) return null;
    users[_int(u['id'])] = u;
    final c = await call({'@type': 'createPrivateChat', 'user_id': u['id'], 'force': false});
    if (isError(c)) return null;
    chats[_int(c['id'])] = Map.of(c);
    return c;
  }

  // ---------------- text helpers ----------------
  static int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  static int idOf(Map m) => _int(m['id']);
  static int chatOf(Map m) => _int(m['chat_id']);

  static bool isChannel(Map chat) {
    final t = chat['type'] as Map?;
    return t?['@type'] == 'chatTypeSupergroup' && t?['is_channel'] == true;
  }

  static bool isPrivate(Map chat) => (chat['type'] as Map?)?['@type'] == 'chatTypePrivate';

  String userName(int id) {
    final u = users[id];
    if (u == null) return 'Someone';
    final n = '${u['first_name'] ?? ''} ${u['last_name'] ?? ''}'.trim();
    return n.isEmpty ? 'Deleted account' : n;
  }

  /// Who sent [m]: a person's name, or the chat's title for channel posts.
  String senderName(Map m) {
    final s = m['sender_id'] as Map?;
    if (s?['@type'] == 'messageSenderUser') {
      final id = _int(s?['user_id']);
      return id == myId ? 'You' : userName(id);
    }
    if (s?['@type'] == 'messageSenderChat') return '${chats[_int(s?['chat_id'])]?['title'] ?? 'Channel'}';
    return 'Someone';
  }

  String chatTitle(int chatId) => '${chats[chatId]?['title'] ?? 'Telegram'}';

  /// Readable text for any kind of message.
  static String textOf(Map m) {
    final c = m['content'] as Map? ?? const {};
    String cap() {
      final t = ((c['caption'] as Map?)?['text'] ?? '').toString();
      return t.isEmpty ? '' : ' $t';
    }

    switch (c['@type']) {
      case 'messageText':
        return ((c['text'] as Map?)?['text'] ?? '').toString();
      case 'messagePhoto':
        return '📷 Photo${cap()}';
      case 'messageVideo':
        return '🎬 Video${cap()}';
      case 'messageAnimation':
        return 'GIF${cap()}';
      case 'messageVoiceNote':
        return '🎤 Voice message${cap()}';
      case 'messageVideoNote':
        return '📹 Video message';
      case 'messageAudio':
        return '🎵 ${((c['audio'] as Map?)?['title'] ?? 'Audio')}${cap()}';
      case 'messageDocument':
        return '📄 ${((c['document'] as Map?)?['file_name'] ?? 'File')}${cap()}';
      case 'messageSticker':
        return '${((c['sticker'] as Map?)?['emoji'] ?? '')} Sticker'.trim();
      case 'messageLocation':
      case 'messageVenue':
        return '📍 Location';
      case 'messageContact':
        return '👤 Contact';
      case 'messagePoll':
        final q = (c['poll'] as Map?)?['question'];
        return '📊 ${q is Map ? q['text'] : q ?? 'Poll'}';
      case 'messageCall':
        return '📞 Call';
      case 'messagePinMessage':
        return '📌 Pinned a message';
      case 'messageChatAddMembers':
        return 'Added members';
      case 'messageChatJoinByLink':
        return 'Joined the group';
      default:
        return 'Message';
    }
  }
}


/// A downloadable file inside a Telegram message.
class TgFile {
  final int id, size;
  final String name, mime, kind; // kind: video / audio / document / photo / voice
  const TgFile(this.id, this.name, this.mime, this.size, this.kind);

  Map toCard() => {'type': 'tgfile', 'file': id, 'name': name, 'mime': mime, 'size': size, 'kind': kind};
  static TgFile fromCard(Map c) => TgFile((c['file'] as num).toInt(), '${c['name']}', '${c['mime']}',
      (c['size'] as num?)?.toInt() ?? 0, '${c['kind']}');

  static TgFile? of(Map msg) {
    final c = msg['content'] as Map? ?? const {};
    final mid = msg['id'];
    TgFile? make(Map? f, String? name, String? mime, String kind, String fallback) {
      if (f == null) return null;
      final size = ((f['size'] as num?) ?? 0) > 0 ? (f['size'] as num).toInt() : ((f['expected_size'] as num?) ?? 0).toInt();
      final n = (name == null || name.trim().isEmpty) ? fallback : name.trim();
      return TgFile((f['id'] as num).toInt(), n, (mime == null || mime.isEmpty) ? 'application/octet-stream' : mime, size, kind);
    }

    switch (c['@type']) {
      case 'messageDocument':
        final d = c['document'] as Map;
        return make(d['document'] as Map?, d['file_name'], d['mime_type'], 'document', 'file_$mid');
      case 'messageVideo':
        final v = c['video'] as Map;
        return make(v['video'] as Map?, v['file_name'], v['mime_type'] ?? 'video/mp4', 'video', 'video_$mid.mp4');
      case 'messageAnimation':
        final v = c['animation'] as Map;
        return make(v['animation'] as Map?, v['file_name'], v['mime_type'] ?? 'video/mp4', 'video', 'gif_$mid.mp4');
      case 'messageAudio':
        final a = c['audio'] as Map;
        final guess = [a['performer'], a['title']].where((x) => x != null && '$x'.isNotEmpty).join(' - ');
        return make(a['audio'] as Map?, a['file_name'] ?? (guess.isEmpty ? null : '$guess.mp3'), a['mime_type'] ?? 'audio/mpeg',
            'audio', 'audio_$mid.mp3');
      case 'messageVoiceNote':
        final v = c['voice_note'] as Map;
        return make(v['voice'] as Map?, null, v['mime_type'] ?? 'audio/ogg', 'voice', 'voice_$mid.ogg');
      case 'messageVideoNote':
        final v = c['video_note'] as Map;
        return make(v['video'] as Map?, null, 'video/mp4', 'video', 'video_note_$mid.mp4');
      case 'messagePhoto':
        final sizes = ((c['photo'] as Map?)?['sizes'] as List?) ?? const [];
        if (sizes.isEmpty) return null;
        return make((sizes.last as Map)['photo'] as Map?, null, 'image/jpeg', 'photo', 'photo_$mid.jpg');
    }
    return null;
  }

  static String human(int b) {
    if (b <= 0) return '';
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }
}
