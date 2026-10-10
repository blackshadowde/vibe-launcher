import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'launcher.dart';

/// One mail found in Gmail.
class MailHit {
  final String from, subject, date, msgId;
  MailHit(this.from, this.subject, this.date, this.msgId);

  /// Opens the mail in Gmail (web link; the Gmail app picks it up if it can).
  String get link {
    final id = BigInt.tryParse(msgId);
    return id == null
        ? 'https://mail.google.com/mail/u/0/#inbox'
        : 'https://mail.google.com/mail/u/0/#all/${id.toRadixString(16)}';
  }
}

/// Tiny IMAP client: signs in to Gmail with an app password and uses Gmail's own search.
/// The password never leaves the phone except to Gmail itself, over TLS.
class Mail {
  static bool get ready => prefs.gmailUser.isNotEmpty && prefs.gmailPass.isNotEmpty;

  static String searchLink(String q) => 'https://mail.google.com/mail/u/0/#search/${Uri.encodeComponent(q)}';

  static String _quote(String s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  /// Returns hits, or throws a readable message.
  static Future<List<MailHit>> search(String query, {int max = 12}) async {
    final sock = await SecureSocket.connect('imap.gmail.com', 993, timeout: const Duration(seconds: 15));
    final buf = StringBuffer();
    final lines = StreamController<void>.broadcast();
    sock.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen((d) {
      buf.write(d);
      lines.add(null);
    }, onError: (_) {}, onDone: () => lines.close());

    var n = 0;
    Future<String> cmd(String c) async {
      final tag = 'V${++n}';
      final start = buf.length;
      final t0 = DateTime.now();
      sock.write('$tag $c\r\n');
      final done = RegExp('(^|\\r\\n)$tag (OK|NO|BAD)[^\\r\\n]*\\r\\n');
      while (true) {
        final text = buf.toString().substring(start);
        final m = done.firstMatch(text);
        if (m != null) {
          if (m.group(2) != 'OK') throw MailError(text.substring(m.start).trim());
          return text.substring(0, m.end);
        }
        if (DateTime.now().difference(t0).inSeconds > 25) throw TimeoutException('imap');
        await Future.any([lines.stream.first.then((_) {}, onError: (_) {}), Future.delayed(const Duration(milliseconds: 200))]);
      }
    }

    try {
      // greeting
      final g0 = DateTime.now();
      while (!buf.toString().contains('\r\n')) {
        if (DateTime.now().difference(g0).inSeconds > 15) throw TimeoutException('imap');
        await Future.any([lines.stream.first.then((_) {}, onError: (_) {}), Future.delayed(const Duration(milliseconds: 200))]);
      }
      try {
        await cmd('LOGIN ${_quote(prefs.gmailUser)} ${_quote(prefs.gmailPass)}');
      } on MailError {
        throw MailError('Gmail didn\'t accept the address or app password. Check them in Vibe settings → Search & mail.');
      }
      // Find "All Mail" (its name depends on the account language)
      final list = await cmd('LIST "" "*"');
      final all = RegExp(r'\* LIST \([^)]*\\All[^)]*\) "[^"]*" (".*?"|\S+)\r\n').firstMatch(list);
      final box = all?.group(1) ?? '"INBOX"';
      await cmd('EXAMINE $box');
      final found = await cmd('UID SEARCH X-GM-RAW ${_quote(query)}');
      final ids = RegExp(r'\* SEARCH([ \d]*)').firstMatch(found)?.group(1)?.trim().split(' ').where((e) => e.isNotEmpty).toList() ?? [];
      if (ids.isEmpty) return [];
      final pick = ids.length > max ? ids.sublist(ids.length - max) : ids;
      final raw = await cmd('UID FETCH ${pick.join(',')} (UID X-GM-MSGID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])');
      final out = <MailHit>[];
      for (final part in raw.split(RegExp(r'\r\n(?=\* \d+ FETCH )|^(?=\* \d+ FETCH )'))) {
        if (!part.contains('FETCH')) continue;
        final msgId = RegExp(r'X-GM-MSGID (\d+)').firstMatch(part)?.group(1) ?? '';
        String header(String name) {
          final m = RegExp('^$name:[ \\t]*(.*(?:\\r\\n[ \\t].*)*)', multiLine: true, caseSensitive: false).firstMatch(part);
          return m == null ? '' : decodeWords(m.group(1)!.replaceAll(RegExp(r'\r\n[ \t]+'), ' ').trim());
        }
        var from = header('From');
        final nameOnly = RegExp(r'^"?([^"<]+?)"?\s*<').firstMatch(from)?.group(1);
        if (nameOnly != null && nameOnly.trim().isNotEmpty) from = nameOnly.trim();
        out.add(MailHit(from, header('Subject').isEmpty ? '(no subject)' : header('Subject'), header('Date'), msgId));
      }
      try {
        await cmd('LOGOUT');
      } catch (_) {}
      return out.reversed.toList(); // newest first
    } on TimeoutException {
      throw MailError('Gmail took too long to answer.');
    } on SocketException {
      throw MailError('Couldn\'t reach Gmail. Are you online?');
    } finally {
      sock.destroy();
    }
  }

  /// Decodes "=?UTF-8?B?...?=" and "=?UTF-8?Q?...?=" pieces in mail headers.
  static String decodeWords(String s) {
    return s.replaceAllMapped(RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]*)\?=\s*'), (m) {
      try {
        final enc = m.group(2)!.toUpperCase();
        List<int> bytes;
        if (enc == 'B') {
          bytes = base64.decode(base64.normalize(m.group(3)!));
        } else {
          final q = m.group(3)!.replaceAll('_', ' ');
          bytes = [];
          for (var i = 0; i < q.length; i++) {
            if (q[i] == '=' && i + 2 < q.length) {
              bytes.add(int.parse(q.substring(i + 1, i + 3), radix: 16));
              i += 2;
            } else {
              bytes.add(q.codeUnitAt(i));
            }
          }
        }
        return utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return m.group(0)!;
      }
    });
  }
}

class MailError implements Exception {
  final String message;
  MailError(this.message);
  @override
  String toString() => message;
}
