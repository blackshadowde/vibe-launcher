import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:handy_tdlib_next/handy_tdlib_next.dart' show TdPlugin;
import 'launcher.dart';

/// A full Telegram account inside Vibe, using Telegram's own library (TDLib).
/// Your API ID / hash come from my.telegram.org and stay encrypted on this phone.
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
    if (c != null && isChannel(c)) return; // channels are news feeds, not chats
    final muted = ((c?['notification_settings'] as Map?)?['mute_for'] as num? ?? 0) > 0;
    if (muted) return;
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
    await loadChats();
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

  /// Chats newest first (channels last).
  List<Map> sortedChats() {
    final l = chats.values.toList();
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
