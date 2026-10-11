import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'launcher.dart';
import 'theme.dart';

// =====================================================================================
// Files in Vibe: Linux commands (ls, cd, find, grep, rm, mv…) and plain words
// ("list the files in downloads", "share movie.mp3", "delete movie.mp3", "edit text.html").
// Results slide up in a pane above the message box; you can keep typing while it's open.
// =====================================================================================

const _textExts = {
  'txt', 'md', 'html', 'htm', 'json', 'csv', 'log', 'xml', 'js', 'css', 'py', 'kt', 'dart', 'java', 'c', 'cpp', 'h',
  'sh', 'yml', 'yaml', 'ini', 'conf', 'srt', 'vtt', 'tex', 'sql', 'toml', 'properties', 'gradle', 'ts', 'tsx', 'jsx',
  'php', 'rb', 'go', 'rs', 'swift', 'bat', 'env', 'cfg', 'tsv', 'svg',
};

class FsItem {
  final String name, path, mime, line, from;
  final bool dir;
  final int size, time, count, ln, at;
  FsItem.fromMap(Map m)
      : name = '${m['n'] ?? ''}',
        path = '${m['p'] ?? ''}',
        mime = '${m['m'] ?? ''}',
        dir = m['d'] == true,
        size = (m['s'] as num?)?.toInt() ?? 0,
        time = (m['t'] as num?)?.toInt() ?? 0,
        count = (m['c'] as num?)?.toInt() ?? -1,
        line = '${m['line'] ?? ''}',
        ln = (m['ln'] as num?)?.toInt() ?? 0,
        from = '${m['from'] ?? ''}',
        at = (m['at'] as num?)?.toInt() ?? 0;

  String get ext => name.contains('.') ? name.split('.').last.toLowerCase() : '';
  bool get isText => !dir && (mime.startsWith('text/') || _textExts.contains(ext) || mime == 'application/json');
  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');
  bool get isApk => ext == 'apk';
}

String fsSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String fsDate(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms), now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return 'Today $hm';
  final y = now.subtract(const Duration(days: 1));
  if (t.year == y.year && t.month == y.month && t.day == y.day) return 'Yesterday $hm';
  return '${t.day} ${_months[t.month - 1]}${t.year == now.year ? '' : ' ${t.year}'}';
}

/// Where you are and how names turn into paths.
class Fs {
  static String root = '/storage/emulated/0';
  static List<String> volumes = ['/storage/emulated/0'];
  static bool access = true;
  static String cwd = '/storage/emulated/0';
  static String prev = '/storage/emulated/0';
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    final h = await Native.fsHome();
    if (h['root'] is String) {
      final r = h['root'] as String;
      if (cwd == root) cwd = r;
      if (prev == root) prev = r;
      root = r;
    }
    volumes = List<String>.from((h['volumes'] as List?) ?? [root]);
    access = h['access'] != false;
    _inited = true;
    Native.fsOp('purge'); // trash older than 30 days
  }

  static Future<bool> checkAccess() async {
    final h = await Native.fsHome();
    access = h['access'] != false;
    return access;
  }

  static String volumeOf(String p) => volumes.firstWhere((v) => p == v || p.startsWith('$v/'), orElse: () => root);

  /// "~/Download/Vibe Telegram" style, for showing.
  static String rel(String p) {
    final v = volumeOf(p);
    final label = v == root ? '~' : 'SD';
    if (p == v) return label;
    if (!p.startsWith('$v/')) return p;
    return '$label/${p.substring(v.length + 1)}';
  }

  static String nameOf(String p) => p == root ? 'Phone storage' : volumes.contains(p) ? 'SD card' : p.split('/').last;
  static String parentOf(String p) {
    if (volumes.contains(p)) return p;
    final i = p.lastIndexOf('/');
    final up = i <= 0 ? p : p.substring(0, i);
    return up.length < volumeOf(p).length ? volumeOf(p) : up;
  }

  static String join(String a, String b) => a.endsWith('/') ? '$a$b' : '$a/$b';

  static String unquote(String s) {
    var t = s.trim();
    if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")))) {
      t = t.substring(1, t.length - 1);
    }
    return t;
  }

  /// Well-known folders you can name in plain words.
  static const aliases = <String, List<String>>{
    'downloads': ['Download'], 'download': ['Download'],
    'documents': ['Documents'], 'docs': ['Documents'], 'document': ['Documents'],
    'pictures': ['Pictures'], 'camera': ['DCIM/Camera'], 'dcim': ['DCIM'], 'photos': ['DCIM/Camera', 'Pictures'],
    'screenshots': ['Pictures/Screenshots', 'DCIM/Screenshots'], 'screenshot': ['Pictures/Screenshots', 'DCIM/Screenshots'],
    'music': ['Music'], 'songs': ['Music'], 'movies': ['Movies'], 'videos': ['Movies'],
    'whatsapp': ['Android/media/com.whatsapp/WhatsApp/Media', 'WhatsApp/Media'],
    'whatsapp media': ['Android/media/com.whatsapp/WhatsApp/Media', 'WhatsApp/Media'],
    'telegram': ['Download/Vibe Telegram', 'Telegram', 'Download/Telegram'],
    'vibe telegram': ['Download/Vibe Telegram'],
    'bluetooth': ['Bluetooth', 'Download/Bluetooth'],
    'recordings': ['Recordings', 'Music/Recordings'],
    'home': [''], 'storage': [''], 'internal storage': [''], 'phone storage': [''], 'phone': [''], 'root': [''],
  };

  static Future<List<FsItem>?> list(String dir, {bool hidden = true}) async {
    final r = await Native.fsList(dir, hidden: hidden);
    if (r['items'] is! List) return null;
    return [for (final m in r['items'] as List) FsItem.fromMap(m as Map)];
  }

  /// 'dir', 'file' or null.
  static Future<String?> kind(String p) async {
    final r = await Native.fsList(p, hidden: true);
    if (r['items'] is List) return 'dir';
    if (r['error'] == 'notdir') return 'file';
    return null;
  }

  static Future<FsItem?> info(String p) async {
    final r = await Native.fsList(p, hidden: true);
    if (r['item'] is Map) return FsItem.fromMap(r['item'] as Map);
    if (r['items'] is List) {
      final up = await list(parentOf(p));
      return up?.where((e) => e.path == p).firstOrNull;
    }
    return null;
  }

  static Future<String?> _child(String dir, String name, {bool fuzzy = true}) async {
    final kids = await list(dir);
    if (kids == null) return null;
    final low = name.toLowerCase();
    for (final k in kids) {
      if (k.name == name) return k.path;
    }
    for (final k in kids) {
      if (k.name.toLowerCase() == low) return k.path;
    }
    if (!fuzzy) return null;
    final starts = kids.where((k) => k.name.toLowerCase().startsWith(low)).toList();
    if (starts.length == 1) return starts.first.path;
    if (low.length >= 3) {
      final has = kids.where((k) => k.name.toLowerCase().contains(low)).toList();
      if (has.length == 1) return has.first.path;
    }
    return null;
  }

  /// Turns "..", "~", "/", "downloads", "Vibe tel" (partial, any case) into a real path.
  /// Null when it doesn't exist; with [create], the path it would have.
  static Future<String?> resolve(String arg, {bool create = false, bool fuzzy = true, bool useAliases = true}) async {
    final a = unquote(arg);
    if (a.isEmpty || a == '.') return cwd;
    if (a == '-') return prev;
    if (a == '~' || a == '/') return root;
    String start, rest;
    if (a.startsWith('~/')) {
      start = root;
      rest = a.substring(2);
    } else if (a.startsWith('/storage/')) {
      start = volumeOf(a);
      rest = a.length > start.length ? a.substring(start.length) : '';
    } else if (a.startsWith('/')) {
      start = root;
      rest = a.substring(1);
    } else {
      start = cwd;
      rest = a;
      final low = a.toLowerCase().replaceAll(RegExp(r'\s+(folder|directory|dir)$'), '').trim();
      if (!low.contains('/')) {
        final here = await _child(cwd, a, fuzzy: false);
        if (here != null) return here;
        if (useAliases && aliases.containsKey(low)) {
          for (final cand in aliases[low]!) {
            final p = cand.isEmpty ? root : join(root, cand);
            if (await kind(p) != null) return p;
          }
        }
        if (useAliases && (low == 'sd card' || low == 'sdcard' || low == 'sd')) {
          if (volumes.length > 1) return volumes[1];
        }
      }
    }
    var cur = start;
    final segs = rest.split('/').where((s) => s.isNotEmpty).toList();
    for (var i = 0; i < segs.length; i++) {
      final s = segs[i];
      if (s == '.') continue;
      if (s == '..') {
        cur = parentOf(cur);
        continue;
      }
      final kid = await _child(cur, s, fuzzy: i < segs.length - 1 || (fuzzy && !create));
      if (kid == null) {
        if (!create) return null;
        return join(cur, segs.sublist(i).where((x) => x != '.').join('/'));
      }
      cur = kid;
    }
    return cur;
  }

  static RegExp globRe(String pattern) {
    final sb = StringBuffer('^');
    for (final ch in pattern.split('')) {
      if (ch == '*') {
        sb.write('.*');
      } else if (ch == '?') {
        sb.write('.');
      } else {
        sb.write(RegExp.escape(ch));
      }
    }
    sb.write(r'$');
    return RegExp(sb.toString(), caseSensitive: false);
  }

  /// "*.jpg" / "Download/*.apk" → matching paths; a plain name → its path (or nothing).
  static Future<List<String>> expand(String arg, {bool fuzzy = true}) async {
    final a = unquote(arg);
    if (!a.contains('*') && !a.contains('?')) {
      final p = await resolve(a, fuzzy: fuzzy, useAliases: fuzzy);
      return p == null ? [] : [p];
    }
    final i = a.lastIndexOf('/');
    final dir = i < 0 ? cwd : await resolve(i == 0 ? '/' : a.substring(0, i));
    if (dir == null) return [];
    final re = globRe(a.substring(i + 1));
    final kids = await list(dir) ?? const [];
    return [for (final k in kids) if (re.hasMatch(k.name) && !k.name.startsWith('.')) k.path];
  }

  /// Files anywhere on the phone with this name (exact first, then containing it).
  static Future<List<FsItem>> lookup(String name, {bool fuzzy = true}) async {
    final n = unquote(name).replaceAll('%', '');
    if (n.isEmpty) return [];
    var r = await Native.fsFind(root: root, like: n, limit: 40);
    var l = [for (final m in (r['items'] as List?) ?? const []) FsItem.fromMap(m as Map)];
    if (l.isEmpty && fuzzy) {
      final words = n.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join('%');
      r = await Native.fsFind(root: root, like: '%$words%', limit: 40);
      l = [for (final m in (r['items'] as List?) ?? const []) FsItem.fromMap(m as Map)];
    }
    return l;
  }
}

// =====================================================================================
// Understanding commands
// =====================================================================================

class FsCmd {
  final String op;
  final List<String> args;
  final Map<String, Object> o;
  final bool natural; // said in plain words (not a Linux command)
  final bool explicit; // mentions files/folders/an extension, so it's surely about files
  const FsCmd(this.op, this.args, {this.o = const {}, this.natural = false, this.explicit = true});

  static List<String> split(String s) {
    final out = <String>[];
    final b = StringBuffer();
    String? q;
    var started = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (q != null) {
        if (ch == q) {
          q = null;
        } else {
          b.write(ch);
        }
      } else if (ch == '"' || ch == "'") {
        q = ch;
        started = true;
      } else if (ch == r'\' && i + 1 < s.length) {
        b.write(s[++i]);
        started = true;
      } else if (ch == ' ' || ch == '\t') {
        if (b.isNotEmpty || started) out.add(b.toString());
        b.clear();
        started = false;
      } else {
        b.write(ch);
        started = true;
      }
    }
    if (b.isNotEmpty || started) out.add(b.toString());
    return out;
  }

  static final _extRe = RegExp(r'\S+\.[A-Za-z0-9]{1,6}\b');
  static final _fileWord = RegExp(
      r'\b(files?|folders?|director(y|ies)|dir|documents?|docs?|pdfs?|photos?|pictures?|pics?|images?|videos?|movies?|songs?|music|audio|mp3s?|mp4s?|apks?|zips?|archives?|screenshots?|downloads?|excel|sheets?|spreadsheets?|ppts?|slides|presentations?|ebooks?|recordings?)\b',
      caseSensitive: false);

  static FsCmd? parse(String raw) {
    var t = raw.trim().replaceFirst(RegExp(r'[?!]+$'), '').trim();
    if (t.isEmpty) return null;
    // "cd..", "cd/", "cd~", "cd-"
    final cdx = RegExp(r'^cd(\.\.|/|~|-)(.*)$').firstMatch(t);
    if (cdx != null) t = 'cd ${cdx.group(1)}${cdx.group(2)}';
    final linux = _linux(t);
    if (linux != null) return linux;
    return _natural(t);
  }

  static FsCmd? _linux(String t) {
    final a = split(t);
    if (a.isEmpty) return null;
    final cmd = a.first.toLowerCase();
    final flags = <String>{};
    final args = <String>[];
    var n = 0;
    String? redirect;
    var append = false;
    for (var i = 1; i < a.length; i++) {
      final x = a[i];
      if (x == '>' || x == '>>') {
        append = x == '>>';
        if (i + 1 < a.length) redirect = a[i + 1];
        break;
      }
      if (x.startsWith('-') && x.length > 1 && !RegExp(r'^-\d').hasMatch(x) && cmd != 'find') {
        if (x == '-n' && i + 1 < a.length && int.tryParse(a[i + 1]) != null) {
          n = int.parse(a[++i]);
          continue;
        }
        for (final f in x.substring(1).split('')) {
          flags.add(f);
        }
        continue;
      }
      args.add(x);
    }
    Map<String, Object> o() => {'flags': flags.join(), if (n > 0) 'n': n};
    switch (cmd) {
      case 'ls' || 'll' || 'la' || 'dir':
        if (cmd == 'dir' && args.isNotEmpty && !args.first.contains('/')) return null;
        if (cmd == 'll') flags.add('l');
        if (cmd == 'la') flags.add('a');
        return FsCmd('ls', args, o: o());
      case 'cd':
        return FsCmd('cd', [args.join(' ')]);
      case 'pwd':
        return a.length == 1 ? const FsCmd('pwd', []) : null;
      case 'df':
        return const FsCmd('df', []);
      case 'du':
        return FsCmd('du', args, o: o());
      case 'tree':
        return FsCmd('tree', args, o: {'n': n > 0 ? n : 2});
      case 'grep':
        if (args.isEmpty) return null;
        return FsCmd('grep', args, o: o());
      case 'locate':
        if (args.isEmpty) return null;
        return FsCmd('find', [], o: {'name': args.join(' ')});
      case 'find':
        return _find(a.sublist(1));
      case 'cat' || 'less' || 'head' || 'tail':
        if (args.length != 1) return null;
        if (!args.first.contains('.') && !args.first.contains('/')) return null; // "cat videos" isn't a file command
        return FsCmd(cmd == 'head' || cmd == 'tail' ? cmd : 'cat', args, o: o());
      case 'nano' || 'vi' || 'vim' || 'nvim' || 'edit':
        if (args.length != 1) return null;
        if (cmd == 'edit' && !args.first.contains('.')) return null;
        return FsCmd('edit', args, o: {'create': cmd != 'edit'});
      case 'touch':
        return args.isEmpty ? null : FsCmd('touch', args);
      case 'mkdir':
        return args.isEmpty ? null : FsCmd('mkdir', args);
      case 'rm' || 'rmdir':
        if (args.isEmpty) return null;
        return FsCmd('rm', args, o: {'flags': cmd == 'rmdir' ? 'r' : flags.join()});
      case 'mv' || 'move':
        if (cmd == 'move' && !(args.length == 2 && args.every((x) => x.contains('/') || x.contains('.')))) return null;
        return args.length < 2 ? null : FsCmd('mv', args);
      case 'cp' || 'copy':
        if (cmd == 'copy' && !(args.length == 2 && args.every((x) => x.contains('/') || x.contains('.')))) return null;
        return args.length < 2 ? null : FsCmd('cp', args, o: o());
      case 'xdg-open':
        return args.isEmpty ? null : FsCmd('open', args);
      case 'stat':
        if (args.length != 1) return null;
        return FsCmd('stat', args);
      case 'wc':
        return args.length == 1 ? FsCmd('wc', args) : null;
      case 'echo':
        if (redirect == null) return null;
        final i = t.indexOf(RegExp(r'\s>>?\s'));
        final text = Fs.unquote(t.substring(4, i < 0 ? t.length : i).trim());
        return FsCmd('echo', [redirect], o: {'text': text, 'append': append});
      case 'man' || 'help':
        if (args.length == 1 && RegExp(r'^(files?|ls|cd|find|grep|rm|mv|cp|shell|linux|commands)$').hasMatch(args.first.toLowerCase())) {
          return const FsCmd('help', []);
        }
        return null;
    }
    return null;
  }

  /// find [path] [-name P | -iname P] [-type f|d] [-size +50M] [-mtime -7] [-mmin -30] | find P
  static FsCmd? _find(List<String> a) {
    final o = <String, Object>{};
    final paths = <String>[];
    var linuxish = a.isEmpty;
    var i = 0;
    String? next() => i < a.length ? a[i++] : null;
    while (i < a.length) {
      final x = a[i++];
      switch (x) {
        case '-name' || '-iname': {
            linuxish = true;
            final v = next();
            if (v != null) o['name'] = v;
        }
        case '-type': {
            linuxish = true;
            final v = next();
            if (v == 'd') o['dirs'] = true;
        }
        case '-size': {
            linuxish = true;
            final v = next();
            final m = v == null ? null : RegExp(r'^([+-]?)(\d+(?:\.\d+)?)([kKmMgG]?)$').firstMatch(v);
            if (m != null) {
              final mult = switch (m.group(3)!.toLowerCase()) { 'k' => 1024, 'm' => 1 << 20, 'g' => 1 << 30, _ => 512 };
              final bytes = (double.parse(m.group(2)!) * mult).round();
              if (m.group(1) == '-') {
                o['max'] = bytes;
              } else {
                o['min'] = bytes;
              }
            }
        }
        case '-mtime' || '-mmin': {
            linuxish = true;
            final v = next();
            final m = v == null ? null : RegExp(r'^([+-]?)(\d+)$').firstMatch(v);
            if (m != null) {
              final ms = int.parse(m.group(2)!) * (x == '-mtime' ? 86400000 : 60000);
              final at = DateTime.now().millisecondsSinceEpoch - ms;
              if (m.group(1) == '+') {
                o['older'] = at;
              } else {
                o['newer'] = at;
              }
            }
        }
        default: {
            if (x.startsWith('-')) {
              linuxish = true;
            } else {
              paths.add(x);
            }
        }
      }
    }
    // "find resume" / "find *.pdf" / "find Download -name x"
    if (!linuxish) {
      if (paths.length == 1 && (paths.first.contains('*') || paths.first.contains('.') || paths.first.contains('/') || paths.first == '~')) {
        linuxish = true;
      } else if (paths.length == 1 && !_fileWord.hasMatch(paths.first)) {
        // "find resume": a name to look for
        return FsCmd('find', const [], o: {'name': paths.first});
      }
    }
    if (!linuxish) return null;
    if (o['name'] == null &&
        paths.isNotEmpty &&
        !RegExp(r'^[.~]+$').hasMatch(paths.last) &&
        (paths.last.contains('*') || (paths.length == 1 && paths.last.contains('.') && !paths.last.contains('/')))) {
      o['name'] = paths.removeLast();
    }
    return FsCmd('find', paths, o: o);
  }

  // ---------- plain words ----------
  static FsCmd? _natural(String t) {
    final low = t.toLowerCase();
    final hasExt = _extRe.hasMatch(t);
    final fileWord = _fileWord.hasMatch(low);
    final explicit = hasExt || fileWord || t.contains('/');
    RegExpMatch? m(String re) => RegExp(re, caseSensitive: false).firstMatch(t);

    // Trash
    if (m(r'^(?:show |open |view )?(?:the |my )?(?:vibe )?(?:trash|recycle ?bin|bin|deleted files)(?: folder)?$') != null) {
      return const FsCmd('trash', [], natural: true);
    }
    if (m(r'^(?:empty|clear|clean)(?: the| my)? (?:trash|recycle ?bin|bin)$') != null) return const FsCmd('emptytrash', [], natural: true);
    final res = m(r'^(?:restore|undelete|recover|bring back)(?: the| my)?(?: file| folder)? (.+?)(?: from (?:the )?(?:trash|bin))?$');
    if (res != null) return FsCmd('restore', [res.group(1)!.trim()], natural: true);

    // Recent / big
    if (m(r'^(?:show |list |find )?(?:my )?(?:recent|latest|newest|new|last) (?:files|downloads|documents)$') != null) {
      return FsCmd('find', [], o: {'recent': true, if (low.contains('download')) 'in': 'downloads'}, natural: true);
    }
    if (m(r'^(?:show |list |find )?(?:my )?(?:big|biggest|large|largest|huge) files$') != null ||
        m(r"^what'?s (?:taking|eating|using|filling)(?: up)?(?: all)?(?: my)? (?:space|storage)$") != null) {
      return FsCmd(low.contains('files') ? 'find' : 'du', low.contains('files') ? [] : ['~'], o: {'big': true}, natural: true);
    }

    // Create
    final mk = m(r'^(?:create|make|new|add)(?: a| an)?(?: new)? (folder|directory|dir|file|text file|note file|html file)(?: named| called)? (.+?)(?: (?:in|inside|under) (?:the |my )?(.+?))?$');
    if (mk != null) {
      final isDir = mk.group(1)!.toLowerCase().startsWith(RegExp(r'folder|dir'));
      var name = Fs.unquote(mk.group(2)!.trim());
      if (!isDir && !name.contains('.')) name = '$name.${mk.group(1)!.toLowerCase().startsWith('html') ? 'html' : 'txt'}';
      return FsCmd(isDir ? 'mkdir' : 'touch', [name], o: {if (mk.group(3) != null) 'in': mk.group(3)!.trim(), 'edit': !isDir}, natural: true);
    }

    // Rename
    final rn = m(r'^rename(?: the)?(?: file| folder)? (.+?) (?:to|as) (.+)$');
    if (rn != null) return FsCmd('rename', [rn.group(1)!.trim(), Fs.unquote(rn.group(2)!.trim())], natural: true);

    // Move / copy
    final mv = m(r'^(move|copy)(?: the| my)?(?: files?| folders?)? (.+?) (?:to|into|in) (?:the |my )?(.+?)(?: folder)?$');
    if (mv != null && (explicit || hasExt)) {
      return FsCmd(mv.group(1)!.toLowerCase() == 'move' ? 'mv' : 'cp', [mv.group(2)!.trim(), mv.group(3)!.trim()], natural: true);
    }

    // Edit
    final ed = m(r'^(?:edit|edi|modify|change|update|open)(?: the| my)?(?: file)?(?: named| called| name)? (.+?)(?: (?:in|with) (?:the )?(?:editor|vibe|text editor))?$');
    if (ed != null && low.startsWith(RegExp(r'edi|modify|change|update')) && (hasExt || low.contains(' file'))) {
      return FsCmd('edit', [ed.group(1)!.trim()], natural: true);
    }
    if (ed != null && low.startsWith('open') && RegExp(r' in (?:the )?(?:editor|text editor)$', caseSensitive: false).hasMatch(t)) {
      return FsCmd('edit', [ed.group(1)!.trim()], natural: true);
    }

    // Share
    final sh = m(r'^(?:share|send)(?: the| my| this| that)?(?: files?)?(?: named| called| name)? (.+?)(?: (?:to|with|via|on|over) .+)?$');
    if (sh != null && !RegExp(r'\blocation\b', caseSensitive: false).hasMatch(t)) {
      final what = sh.group(1)!.trim();
      final last = RegExp(r'^(?:the )?(?:last|latest|newest|recent) (screenshot|photo|picture|pic|video|download|file|song|recording|pdf|document|apk)s?$', caseSensitive: false).firstMatch(what);
      if (last != null) return FsCmd('share', const [], o: {'latest': last.group(1)!.toLowerCase()}, natural: true);
      if (hasExt || low.contains(' file') || what.contains('*') || what.contains('/')) {
        return FsCmd('share', [what], natural: true);
      }
    }

    // Delete
    final del = m(r'^(?:delete|remove|trash|erase|bin|get rid of)(?: the| my| this| that)?(?: files?| folders?)?(?: named| called| name| with name)? (.+)$');
    if (del != null) {
      final what = del.group(1)!.trim();
      if (!RegExp(r'^(?:reminder|alarm|event|message|chat|contact|memory|key|api)', caseSensitive: false).hasMatch(what)) {
        return FsCmd('rm', [what], o: {'flags': 'r'}, natural: true, explicit: explicit);
      }
    }

    // "downloads", "my screenshots folder"
    final bare = m(r'^(?:my )?(downloads|documents|screenshots|dcim|camera folder|download folder|whatsapp media|telegram folder|vibe telegram)(?: folder)?$');
    if (bare != null) return FsCmd('open', [bare.group(1)!.replaceAll(RegExp(r' folder$'), '')], natural: true);
    if (m(r'^(?:show |open |browse |list )?(?:me )?(?:my |all )?(?:my )?(?:files|storage|phone storage|internal storage)$') != null) {
      return const FsCmd('open', ['~'], natural: true);
    }

    // Open / list a folder (or open a file with its app)
    final op = m(r'^(?:please )?(?:list|show|display|open|view|browse|go to|goto|take me to|navigate to|show me)(?: me)?(?: all)?(?: the| my)?(?: files| contents| items| stuff)?(?: (?:in|inside|of|from|at))?(?: the| my)? (.+?)(?: (?:folder|directory|dir))?$');
    if (op != null) {
      final what = op.group(1)!.trim();
      // "show pdfs from today", "list big videos": a search, unless it's simply a folder's name
      final searchy = RegExp(
              r'\b(pdfs?|photos?|pictures?|images?|videos?|songs?|mp3s?|apks?|zips?|screenshots?|documents?|docs|excel|spreadsheets?|presentations?|ebooks?|recordings?)\b.*\b(today|yesterday|week|month|recent|latest|newest|big|biggest|large|largest|days?|named|called|with)\b|'
              r'\b(today|yesterday|this week|last week|this month|recent|latest|newest|biggest|largest|big|large)\b.*\b(files?|pdfs?|photos?|pictures?|videos?|songs?|apks?|screenshots?|documents?|downloads?)\b',
              caseSensitive: false)
          .hasMatch(what);
      if (searchy && !Fs.aliases.containsKey(what.toLowerCase())) {
        return FsCmd('find', const [], o: {'words': what}, natural: true);
      }
      final named = RegExp(r'\b(files?|folders?|director(y|ies)|contents)\b', caseSensitive: false).hasMatch(low);
      return FsCmd('open', [what], natural: true, explicit: named || hasExt || what.contains('/'));
    }

    // Search
    final se = m(r'^(?:search|find|look|locate|where(?: is| are|.?s)?|get|show)\b(.*)$');
    if (se != null && (explicit || low.startsWith('search file'))) {
      return FsCmd('find', const [], o: {'words': se.group(1)!.trim()}, natural: true);
    }
    return null;
  }
}

/// Plain-words search: "pdfs from today", "file named resume", "photos from yesterday in whatsapp".
class _Spec {
  String? like, mime, inArg;
  List<String> exts = [];
  int newer = 0, older = 0, min = 0;
  bool bySize = false;
  String title = '';
}

_Spec _specFrom(String words) {
  final s = _Spec();
  var w = ' ${words.toLowerCase()} ';
  final now = DateTime.now();
  final midnight = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  const day = 86400000;
  final whenL = <String>[];
  void time(String re, int newer, [int older = 0, String label = '']) {
    final m = RegExp(re).firstMatch(w);
    if (m == null) return;
    w = w.replaceRange(m.start, m.end, ' ');
    s.newer = newer;
    s.older = older;
    if (label.isNotEmpty) whenL.add(label);
  }

  final nowMs = now.millisecondsSinceEpoch;
  time(r' (?:from |of |since )?today ', midnight, 0, 'today');
  time(r' (?:from |of )?yesterday ', midnight - day, midnight, 'yesterday');
  time(r' (?:from |of )?this week ', nowMs - 7 * day, 0, 'this week');
  time(r' (?:from |of )?last week ', nowMs - 14 * day, nowMs - 7 * day, 'last week');
  time(r' (?:from |of )?this month ', nowMs - 30 * day, 0, 'this month');
  final lastN = RegExp(r' (?:from |in )?(?:the )?(?:last|past) (\d+) days? ').firstMatch(w);
  if (lastN != null) {
    final d = int.parse(lastN.group(1)!);
    w = w.replaceRange(lastN.start, lastN.end, ' ');
    s.newer = nowMs - d * day;
    whenL.add('last $d days');
  }
  if (RegExp(r' (?:recent|latest|newest|new) ').hasMatch(w)) {
    w = w.replaceAll(RegExp(r' (?:recent|latest|newest|new) '), ' ');
    if (s.newer == 0) s.newer = nowMs - 30 * day;
  }
  if (RegExp(r' (?:big|biggest|large|largest|huge) ').hasMatch(w)) {
    w = w.replaceAll(RegExp(r' (?:big|biggest|large|largest|huge) '), ' ');
    s.min = 50 << 20;
    s.bySize = true;
  }
  // "in downloads", "from whatsapp"
  final inM = RegExp(r' (?:in|inside|under|from) (?:the |my )?(.+?)(?: folder)? $').firstMatch(w);
  if (inM != null) {
    s.inArg = inM.group(1)!.trim();
    w = w.replaceRange(inM.start, w.length, ' ');
  }
  // Kinds of files
  String kind = '';
  void type(String re, String label, {String? mime, List<String> exts = const []}) {
    if (kind.isNotEmpty) return;
    final m = RegExp(' (?:$re) ').firstMatch(w);
    if (m == null) return;
    w = w.replaceRange(m.start, m.end, ' ');
    kind = label;
    s.mime = mime;
    s.exts = exts;
  }

  type(r'screenshots?', 'Screenshots', mime: 'image/%');
  if (kind == 'Screenshots') s.like = '%screenshot%';
  type(r'photos?|pictures?|pics?|images?', 'Photos', mime: 'image/%');
  type(r'videos?|movies?|clips?', 'Videos', mime: 'video/%');
  type(r'songs?|music|audio|mp3s?', 'Songs', mime: 'audio/%');
  type(r'recordings?|voice notes?', 'Recordings', mime: 'audio/%');
  type(r'pdfs?', 'PDFs', exts: ['pdf']);
  type(r'apks?|app files?|apps?', 'APKs', exts: ['apk', 'apks', 'xapk']);
  type(r'zips?|archives?|rars?', 'Archives', exts: ['zip', 'rar', '7z', 'tar', 'gz']);
  type(r'excel|spreadsheets?|sheets?|xlsx?', 'Spreadsheets', exts: ['xls', 'xlsx', 'csv', 'ods']);
  type(r'ppts?|pptx|slides|presentations?', 'Presentations', exts: ['ppt', 'pptx', 'odp', 'key']);
  type(r'word files?|word docs?|docx?', 'Word files', exts: ['doc', 'docx', 'odt', 'rtf']);
  type(r'ebooks?|books?|epubs?', 'eBooks', exts: ['epub', 'pdf', 'mobi', 'azw3']);
  type(r'documents?|docs', 'Documents', exts: ['pdf', 'doc', 'docx', 'txt', 'odt', 'rtf', 'xls', 'xlsx', 'ppt', 'pptx', 'csv', 'md']);
  type(r'notes?|text files?|txt', 'Text files', exts: ['txt', 'md']);
  type(r'html files?|web pages?', 'HTML files', exts: ['html', 'htm']);
  // What's left is the name
  final name = w
      .replaceAll(RegExp(r' (?:for|of|the|a|an|my|all|me|any|some|with|that|has|having|named|called|name|names|file|files|folder|folders|which|is|are|where|whose|on|phone|storage|please) '), ' ')
      .replaceAll(RegExp(r' (?:for|of|the|a|an|my|all|me|any|some|with|that|has|having|named|called|name|names|file|files|folder|folders|which|is|are|where|whose|on|phone|storage|please) '), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.isNotEmpty) {
    final n = name.replaceAll('%', '').replaceAll('*', '%');
    // "movie.mp3" is an exact name; "resume" can be part of one
    s.like = RegExp(r'\.[a-z0-9]{1,6}$').hasMatch(n) ? n : '%${n.replaceAll(' ', '%')}%';
  }
  s.title = [
    if (kind.isNotEmpty) kind else 'Files',
    if (name.isNotEmpty) 'matching "$name"',
    ...whenL,
    if (s.bySize) 'over 50 MB',
  ].join(' ');
  return s;
}

// =====================================================================================
// The pane
// =====================================================================================

class FsPane extends ChangeNotifier {
  FsPane._();
  static final FsPane i = FsPane._();

  bool open = false, loading = false, partial = false;
  String mode = 'dir'; // dir / results / trash
  String path = '', title = '', sub = '', error = '';
  String sort = 'name'; // name / time / size
  bool desc = false, hidden = false;
  List<FsItem> items = [];
  final selected = <String>{};
  String? clipOp; // copy / move
  List<String> clip = [];
  double frac = 0.5;

  void _sort() {
    int cmp(FsItem a, FsItem b) {
      if (mode == 'dir' && a.dir != b.dir) return a.dir ? -1 : 1;
      final r = switch (sort) {
        'time' => b.time.compareTo(a.time),
        'size' => b.size.compareTo(a.size),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      return desc ? -r : r;
    }

    items.sort(cmp);
  }

  Future<void> openDir(String p, {String? sortBy, bool? showHidden}) async {
    if (Fs.cwd != p) Fs.prev = Fs.cwd;
    Fs.cwd = p;
    mode = 'dir';
    path = p;
    open = true;
    selected.clear();
    if (sortBy != null) sort = sortBy;
    if (showHidden != null) hidden = showHidden;
    await refresh();
  }

  Future<void> refresh() async {
    if (mode == 'dir') {
      loading = true;
      notifyListeners();
      final r = await Native.fsList(path, hidden: hidden);
      loading = false;
      if (r['items'] is List) {
        items = [for (final m in r['items'] as List) FsItem.fromMap(m as Map)];
        error = '';
        _sort();
      } else {
        items = [];
        error = '${r['error']}';
      }
      title = Fs.nameOf(path);
      sub = Fs.rel(path);
    } else if (mode == 'trash') {
      loading = true;
      notifyListeners();
      items = [for (final m in await Native.fsTrash()) FsItem.fromMap(m)];
      loading = false;
      title = 'Trash';
      sub = items.isEmpty ? 'Empty' : '${items.length} items · emptied after 30 days';
    } else {
      // Results: drop anything that no longer exists
      final keep = <FsItem>[];
      for (final it in items) {
        if (await Fs.kind(it.path) != null) keep.add(it);
      }
      items = keep;
    }
    selected.removeWhere((p) => !items.any((e) => e.path == p));
    notifyListeners();
  }

  void showResults(String t, String s, List<FsItem> list, {bool bySize = false, bool part = false}) {
    mode = 'results';
    title = t;
    sub = s;
    items = list;
    partial = part;
    open = true;
    loading = false;
    error = '';
    selected.clear();
    if (bySize) items.sort((a, b) => b.size.compareTo(a.size));
    notifyListeners();
  }

  void busy(String t) {
    mode = 'results';
    title = t;
    sub = 'Searching…';
    items = [];
    open = true;
    loading = true;
    error = '';
    notifyListeners();
  }

  Future<void> showTrash() async {
    mode = 'trash';
    open = true;
    selected.clear();
    await refresh();
  }

  void close() {
    open = false;
    selected.clear();
    notifyListeners();
  }

  /// Back: up a folder; at the top (or on results), close.
  void back() {
    if (selected.isNotEmpty) {
      selected.clear();
      notifyListeners();
    } else if (mode == 'dir' && !Fs.volumes.contains(path)) {
      openDir(Fs.parentOf(path));
    } else {
      close();
    }
  }

  void setSort(String s) {
    if (sort == s) {
      desc = !desc;
    } else {
      sort = s;
      desc = false;
    }
    _sort();
    notifyListeners();
  }

  void toggle(String p) {
    selected.contains(p) ? selected.remove(p) : selected.add(p);
    notifyListeners();
  }

  void setFrac(double f) {
    frac = f.clamp(0.22, 0.88);
    notifyListeners();
  }
}

/// The pane above the message box. [onScan] checks a file with VirusTotal; [onEdit] opens the editor.
class FilesPaneHost extends StatelessWidget {
  final void Function(String path, String name) onScan;
  final void Function(String path) onEdit;
  const FilesPaneHost({super.key, required this.onScan, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FsPane.i,
      builder: (context, _) {
        final p = FsPane.i;
        final mq = MediaQuery.of(context);
        final screen = mq.size.height;
        final maxH = (screen - mq.viewInsets.bottom - mq.padding.vertical - 230).clamp(150.0, screen);
        final h = (screen * p.frac).clamp(150.0, maxH);
        return AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: p.open
              ? SizedBox(height: h, child: _FilesPane(onScan: onScan, onEdit: onEdit, screen: screen))
              : const SizedBox(width: double.infinity, height: 0),
        );
      },
    );
  }
}

class _FilesPane extends StatelessWidget {
  final void Function(String path, String name) onScan;
  final void Function(String path) onEdit;
  final double screen;
  const _FilesPane({required this.onScan, required this.onEdit, required this.screen});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final p = FsPane.i;
    final selecting = p.selected.isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: c.pane,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.divider),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, -2))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        // Drag to resize, flick down to close
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) => p.setFrac(p.frac - d.delta.dy / screen),
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 900 || p.frac <= 0.23) p.close();
          },
          child: Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Center(
              child: Container(width: 38, height: 4, decoration: BoxDecoration(color: c.faint, borderRadius: BorderRadius.circular(2))),
            ),
          ),
        ),
        _header(context, c, p, selecting),
        if (p.mode == 'dir' && !selecting) _crumbs(c, p),
        if (p.clipOp != null && p.mode == 'dir') _pasteBar(context, c, p),
        Divider(height: 1, color: c.divider),
        Expanded(child: _body(context, c, p)),
        if (selecting) _selectionBar(context, c, p),
      ]),
    );
  }

  Widget _header(BuildContext context, VC c, FsPane p, bool selecting) {
    if (selecting) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
        child: Row(children: [
          IconButton(icon: Icon(Icons.close_rounded, color: c.text), onPressed: () {
            p.selected.clear();
            p.refresh();
          }),
          Expanded(child: Text('${p.selected.length} selected', style: TextStyle(color: c.text, fontWeight: FontWeight.w800, fontSize: 16))),
          TextButton(
            onPressed: () {
              prefs.tap();
              if (p.selected.length == p.items.length) {
                p.selected.clear();
              } else {
                p.selected.addAll(p.items.map((e) => e.path));
              }
              p.refresh();
            },
            child: Text(p.selected.length == p.items.length ? 'None' : 'All', style: TextStyle(color: VC.blurple, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
    }
    final icon = p.mode == 'trash' ? Icons.delete_outline_rounded : p.mode == 'dir' ? Icons.folder_open_rounded : Icons.manage_search_rounded;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 2),
      child: Row(children: [
        Icon(icon, color: VC.blurple, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.text, fontWeight: FontWeight.w800, fontSize: 16)),
            Text(
                p.loading
                    ? (p.mode == 'results' ? 'Searching…' : 'Loading…')
                    : p.mode == 'dir'
                        ? '${p.items.length} items · ${p.sub}'
                        : '${p.sub}${p.partial ? ' · stopped early (big storage)' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.faint, fontSize: 12)),
          ]),
        ),
        if (p.mode == 'dir' && !Fs.volumes.contains(p.path))
          IconButton(
            tooltip: 'Up',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.arrow_upward_rounded, color: c.muted),
            onPressed: () {
              prefs.tap();
              p.openDir(Fs.parentOf(p.path));
            },
          ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert_rounded, color: c.muted),
          color: c.pane,
          onSelected: (v) => _menu(context, p, v),
          itemBuilder: (_) => [
            if (p.mode != 'trash') ...[
              _mi(c, 'sort:name', 'Sort by name', p.sort == 'name'),
              _mi(c, 'sort:time', 'Sort by date', p.sort == 'time'),
              _mi(c, 'sort:size', 'Sort by size', p.sort == 'size'),
            ],
            if (p.mode == 'dir') ...[
              _mi(c, 'hidden', 'Show hidden files', p.hidden),
              _mi(c, 'mkdir', 'New folder', null),
              _mi(c, 'touch', 'New text file', null),
              _mi(c, 'refresh', 'Refresh', null),
            ],
            if (p.mode == 'trash') _mi(c, 'empty', 'Empty trash', null),
            _mi(c, 'trash', 'Open trash', null),
          ],
        ),
        IconButton(
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.close_rounded, color: c.muted),
          onPressed: () {
            prefs.tap();
            p.close();
          },
        ),
      ]),
    );
  }

  PopupMenuItem<String> _mi(VC c, String v, String label, bool? on) => PopupMenuItem(
        value: v,
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: c.text))),
          if (on == true) Icon(Icons.check_rounded, size: 18, color: VC.blurple),
        ]),
      );

  Future<void> _menu(BuildContext context, FsPane p, String v) async {
    prefs.tap();
    if (v.startsWith('sort:')) {
      p.setSort(v.substring(5));
      return;
    }
    switch (v) {
      case 'hidden': {
          p.hidden = !p.hidden;
          await p.refresh();
      }
      case 'refresh': {
          await p.refresh();
      }
      case 'trash': {
          await p.showTrash();
      }
      case 'empty': {
          if (await _confirm(context, 'Empty trash?', 'Everything in the trash is deleted for good.', 'Empty')) {
            await Native.fsOp('emptyTrash');
            await p.refresh();
          }
      }
      case 'mkdir' || 'touch': {
          final name = await _ask(context, v == 'mkdir' ? 'New folder' : 'New text file', v == 'mkdir' ? 'Folder name' : 'notes.txt');
          if (name == null || name.trim().isEmpty) return;
          var n = name.trim();
          if (v == 'touch' && !n.contains('.')) n = '$n.txt';
          final dest = Fs.join(p.path, n);
          final r = await Native.fsOp(v, dest: dest);
          await p.refresh();
          if ('${r['error']}'.isNotEmpty && context.mounted) {
            _snack(context, r['error'] == 'exists' ? '"$n" already exists' : 'Couldn\'t create "$n"');
          } else if (v == 'touch') {
            onEdit(dest);
          }
      }
    }
  }

  Widget _crumbs(VC c, FsPane p) {
    final v = Fs.volumeOf(p.path);
    final parts = <(String, String)>[(v == Fs.root ? 'Phone' : 'SD card', v)];
    if (p.path.length > v.length) {
      var cur = v;
      for (final s in p.path.substring(v.length + 1).split('/')) {
        cur = Fs.join(cur, s);
        parts.add((s, cur));
      }
    }
    const quick = [('Downloads', 'downloads'), ('Camera', 'camera'), ('Screenshots', 'screenshots'), ('Documents', 'documents'), ('WhatsApp', 'whatsapp'), ('Telegram', 'telegram'), ('Music', 'music')];
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) Icon(Icons.chevron_right_rounded, size: 18, color: c.faint),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () {
                prefs.tap();
                p.openDir(parts[i].$2);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                child: Text(parts[i].$1,
                    style: TextStyle(
                        color: i == parts.length - 1 ? c.text : VC.blurple,
                        fontWeight: i == parts.length - 1 ? FontWeight.w800 : FontWeight.w600,
                        fontSize: 13)),
              ),
            ),
          ],
          if (p.path == Fs.root) ...[
            const SizedBox(width: 10),
            for (final (label, alias) in quick)
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  onPressed: () async {
                    prefs.tap();
                    final to = await Fs.resolve(alias);
                    if (to != null) p.openDir(to);
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _pasteBar(BuildContext context, VC c, FsPane p) => Container(
        color: VC.blurple.withValues(alpha: 0.12),
        padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
        child: Row(children: [
          Icon(p.clipOp == 'move' ? Icons.drive_file_move_rounded : Icons.copy_rounded, size: 18, color: VC.blurple),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${p.clip.length} ${p.clip.length == 1 ? 'item' : 'items'} to ${p.clipOp}',
                style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          TextButton(
            onPressed: () async {
              prefs.tap();
              final op = p.clipOp!;
              final r = await Native.fsOp(op, paths: p.clip, dest: p.path);
              p.clipOp = null;
              p.clip = [];
              await p.refresh();
              if (context.mounted) {
                final n = (r['done'] as List?)?.length ?? 0;
                _snack(context, '${'${r['error']}'.isEmpty ? '✓' : '⚠️'} ${op == 'move' ? 'Moved' : 'Copied'} $n ${n == 1 ? 'item' : 'items'} here');
              }
            },
            child: Text('Paste here', style: TextStyle(color: VC.blurple, fontWeight: FontWeight.w800)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, size: 18, color: c.muted),
            onPressed: () {
              p.clipOp = null;
              p.clip = [];
              p.refresh();
            },
          ),
        ]),
      );

  Widget _body(BuildContext context, VC c, FsPane p) {
    if (p.loading && p.items.isEmpty) {
      return Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: VC.blurple)));
    }
    if (p.error.isNotEmpty) {
      final msg = switch (p.error) {
        'missing' => 'This folder doesn\'t exist anymore.',
        'blocked' => 'Android keeps this folder private to its app.',
        'denied' => 'Vibe can\'t read this folder. Allow "All files access".',
        _ => 'Couldn\'t open this folder (${p.error}).',
      };
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(msg, textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
            if (p.error == 'denied')
              TextButton(onPressed: Native.requestFiles, child: Text('Allow all files access', style: TextStyle(color: VC.blurple))),
          ]),
        ),
      );
    }
    if (p.items.isEmpty) {
      return Center(
        child: Text(p.mode == 'dir' ? 'Empty folder' : p.mode == 'trash' ? 'Trash is empty' : 'Nothing found',
            style: TextStyle(color: c.faint, fontSize: 15, fontWeight: FontWeight.w600)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 6),
      itemCount: p.items.length,
      itemBuilder: (_, i) => _tile(context, c, p, p.items[i]),
    );
  }

  Widget _tile(BuildContext context, VC c, FsPane p, FsItem it) {
    final sel = p.selected.contains(it.path);
    final selecting = p.selected.isNotEmpty;
    final subParts = <String>[
      if (p.mode == 'trash') ...[
        if (it.from.isNotEmpty) 'from ${Fs.rel(Fs.parentOf(it.from))}',
        'deleted ${fsDate(it.at)}',
      ] else if (it.line.isNotEmpty) ...[
        'line ${it.ln}: ${it.line}',
      ] else ...[
        if (it.dir && it.count >= 0 && p.mode == 'dir') '${it.count} items' else if (!it.dir || it.size > 0) fsSize(it.size),
        fsDate(it.time),
        if (p.mode == 'results') Fs.rel(Fs.parentOf(it.path)),
      ],
    ];
    return Material(
      color: sel ? VC.blurple.withValues(alpha: 0.14) : Colors.transparent,
      child: InkWell(
        onTap: () {
          prefs.tap();
          if (selecting) {
            p.toggle(it.path);
          } else {
            _openItem(context, p, it);
          }
        },
        onLongPress: () {
          prefs.heavy();
          p.toggle(it.path);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 2, 6),
          child: Row(children: [
            Stack(children: [
              FsIcon(item: it, size: 42),
              if (sel)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(color: VC.blurple, shape: BoxShape.circle, border: Border.all(color: c.pane, width: 2)),
                    child: const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                  ),
                ),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 14.5)),
                Text(subParts.where((e) => e.isNotEmpty).join(' · '),
                    maxLines: it.line.isNotEmpty ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.faint, fontSize: 12)),
              ]),
            ),
            if (!selecting)
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, size: 20, color: c.faint),
                color: c.pane,
                onSelected: (v) => _itemAction(context, p, it, v),
                itemBuilder: (_) => [
                  if (p.mode == 'trash') ...[
                    _mi(c, 'restore', 'Restore', null),
                    _mi(c, 'forever', 'Delete forever', null),
                  ] else ...[
                    _mi(c, 'open', it.dir ? 'Open folder' : 'Open', null),
                    if (it.isText) _mi(c, 'edit', 'Edit in Vibe', null),
                    if (!it.dir) _mi(c, 'share', 'Share', null),
                    if (!it.dir) _mi(c, 'scan', 'Scan with VirusTotal', null),
                    if (p.mode == 'results') _mi(c, 'reveal', 'Show in folder', null),
                    _mi(c, 'copy', 'Copy to…', null),
                    _mi(c, 'move', 'Move to…', null),
                    _mi(c, 'rename', 'Rename', null),
                    _mi(c, 'path', 'Copy path', null),
                    _mi(c, 'delete', 'Delete', null),
                  ],
                ],
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _openItem(BuildContext context, FsPane p, FsItem it) async {
    if (p.mode == 'trash') return;
    if (it.dir) {
      await p.openDir(it.path);
      return;
    }
    if (it.isText && it.size < 2 << 20) {
      onEdit(it.path);
      return;
    }
    final r = await Native.fsOpen(it.path);
    if (!context.mounted) return;
    if (r == 'apk') _snack(context, 'To install, open it from your Files app (Vibe doesn\'t install apps).');
    if (r == 'noapp') _snack(context, 'No app on your phone opens this kind of file.');
    if (r == 'missing') p.refresh();
  }

  Future<void> _itemAction(BuildContext context, FsPane p, FsItem it, String v) async {
    prefs.tap();
    switch (v) {
      case 'open': {
          if (it.dir) {
            await p.openDir(it.path);
          } else {
            final r = await Native.fsOpen(it.path);
            if (context.mounted && r == 'apk') _snack(context, 'To install, open it from your Files app.');
            if (context.mounted && r == 'noapp') _snack(context, 'No app on your phone opens this kind of file.');
          }
      }
      case 'edit': {
          onEdit(it.path);
      }
      case 'share': {
          await Native.fsShare([it.path]);
      }
      case 'scan': {
          onScan(it.path, it.name);
      }
      case 'reveal': {
          await p.openDir(Fs.parentOf(it.path));
          p.selected.add(it.path);
          p.refresh();
      }
      case 'copy' || 'move': {
          p.clipOp = v;
          p.clip = [it.path];
          if (p.mode != 'dir') await p.openDir(Fs.parentOf(it.path));
          p.refresh();
          if (context.mounted) _snack(context, 'Go to a folder and tap "Paste here".');
      }
      case 'rename': {
          final n = await _ask(context, 'Rename', it.name, initial: it.name);
          if (n == null || n.trim().isEmpty || n.trim() == it.name) return;
          final r = await Native.fsOp('rename', paths: [it.path], name: n.trim());
          if (context.mounted && '${r['error']}'.isNotEmpty) _snack(context, r['error'] == 'exists' ? '"${n.trim()}" already exists' : 'Couldn\'t rename');
          if (p.mode == 'results') {
            final i = p.items.indexWhere((e) => e.path == it.path);
            final np = Fs.join(Fs.parentOf(it.path), n.trim());
            final ni = await Fs.info(np);
            if (i >= 0 && ni != null) p.items[i] = ni;
          }
          await p.refresh();
      }
      case 'path': {
          await Clipboard.setData(ClipboardData(text: it.path));
          if (context.mounted) _snack(context, 'Path copied');
      }
      case 'delete': {
          await _trash(context, p, [it.path]);
      }
      case 'restore': {
          await Native.fsOp('restore', paths: [it.path]);
          await p.refresh();
          if (context.mounted) _snack(context, 'Restored ${it.name}');
      }
      case 'forever': {
          if (await _confirm(context, 'Delete for good?', '"${it.name}" can\'t be brought back.', 'Delete')) {
            await Native.fsOp('delete', paths: [it.path]);
            await p.refresh();
          }
      }
    }
  }

  Future<void> _trash(BuildContext context, FsPane p, List<String> paths) async {
    final r = await Native.fsOp('trash', paths: paths);
    final done = List<String>.from((r['done'] as List?) ?? const []);
    if (p.mode == 'results') p.items.removeWhere((e) => paths.contains(e.path));
    p.selected.clear();
    await p.refresh();
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(done.isEmpty ? 'Couldn\'t delete' : 'Moved ${done.length} ${done.length == 1 ? 'item' : 'items'} to trash'),
      action: done.isEmpty
          ? null
          : SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                await Native.fsOp('restore', paths: done);
                await p.refresh();
              },
            ),
    ));
  }

  Widget _selectionBar(BuildContext context, VC c, FsPane p) {
    final sel = p.items.where((e) => p.selected.contains(e.path)).toList();
    final files = sel.where((e) => !e.dir).toList();
    Widget act(IconData i, String label, VoidCallback? f) => Opacity(
          opacity: f == null ? 0.35 : 1,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: f == null
                ? null
                : () {
                    prefs.tap();
                    f();
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(i, color: c.text, size: 22),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(color: c.muted, fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.divider))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: p.mode == 'trash'
              ? [
                  act(Icons.restore_rounded, 'Restore', () async {
                    await Native.fsOp('restore', paths: sel.map((e) => e.path).toList());
                    p.selected.clear();
                    await p.refresh();
                  }),
                  act(Icons.delete_forever_rounded, 'Delete forever', () async {
                    if (await _confirm(context, 'Delete ${sel.length} for good?', 'They can\'t be brought back.', 'Delete')) {
                      await Native.fsOp('delete', paths: sel.map((e) => e.path).toList());
                      p.selected.clear();
                      await p.refresh();
                    }
                  }),
                ]
              : [
                  act(Icons.share_rounded, 'Share', files.isEmpty ? null : () => Native.fsShare(files.map((e) => e.path).toList())),
                  act(Icons.shield_outlined, 'Scan', files.length == 1 ? () => onScan(files.first.path, files.first.name) : null),
                  act(Icons.copy_rounded, 'Copy', () async {
                    p.clipOp = 'copy';
                    p.clip = sel.map((e) => e.path).toList();
                    p.selected.clear();
                    if (p.mode != 'dir') await p.openDir(Fs.parentOf(sel.first.path));
                    p.refresh();
                    if (context.mounted) _snack(context, 'Go to a folder and tap "Paste here".');
                  }),
                  act(Icons.drive_file_move_rounded, 'Move', () async {
                    p.clipOp = 'move';
                    p.clip = sel.map((e) => e.path).toList();
                    p.selected.clear();
                    if (p.mode != 'dir') await p.openDir(Fs.parentOf(sel.first.path));
                    p.refresh();
                    if (context.mounted) _snack(context, 'Go to a folder and tap "Paste here".');
                  }),
                  act(Icons.drive_file_rename_outline_rounded, 'Rename', sel.length == 1 ? () => _itemAction(context, p, sel.first, 'rename') : null),
                  act(Icons.edit_note_rounded, 'Edit', sel.length == 1 && sel.first.isText ? () => onEdit(sel.first.path) : null),
                  act(Icons.delete_outline_rounded, 'Delete', () => _trash(context, p, sel.map((e) => e.path).toList())),
                ],
        ),
      ),
    );
  }
}

void _snack(BuildContext context, String text) => ScaffoldMessenger.maybeOf(context)
    ?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));

Future<bool> _confirm(BuildContext context, String title, String body, String yes) async {
  final c = VC.of(context);
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.pane,
      title: Text(title, style: TextStyle(color: c.text)),
      content: Text(body, style: TextStyle(color: c.muted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes, style: const TextStyle(color: VC.red))),
      ],
    ),
  );
  return r == true;
}

Future<String?> _ask(BuildContext context, String title, String hint, {String initial = ''}) {
  final c = VC.of(context);
  final ctl = TextEditingController(text: initial);
  if (initial.contains('.')) ctl.selection = TextSelection(baseOffset: 0, extentOffset: initial.lastIndexOf('.'));
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.pane,
      title: Text(title, style: TextStyle(color: c.text)),
      content: TextField(
        controller: ctl,
        autofocus: true,
        style: TextStyle(color: c.text),
        decoration: InputDecoration(hintText: hint, hintStyle: TextStyle(color: c.faint)),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('OK')),
      ],
    ),
  );
}

/// File icon, or a little picture for photos, videos and songs.
class FsIcon extends StatelessWidget {
  final FsItem item;
  final double size;
  const FsIcon({super.key, required this.item, this.size = 42});

  static final _cache = <String, Future<Uint8List?>>{};

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final it = item;
    final (IconData icon, Color col) = it.dir
        ? (Icons.folder_rounded, const Color(0xFFF0B232))
        : it.isImage
            ? (Icons.image_rounded, const Color(0xFF3BA55C))
            : it.isVideo
                ? (Icons.movie_rounded, const Color(0xFFED4245))
                : it.isAudio
                    ? (Icons.music_note_rounded, const Color(0xFFEB459E))
                    : it.ext == 'pdf'
                        ? (Icons.picture_as_pdf_rounded, const Color(0xFFED4245))
                        : it.isApk
                            ? (Icons.android_rounded, const Color(0xFF3BA55C))
                            : const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(it.ext)
                                ? (Icons.folder_zip_rounded, const Color(0xFFF0B232))
                                : it.isText
                                    ? (Icons.description_rounded, const Color(0xFF00A8FC))
                                    : (Icons.insert_drive_file_rounded, c.muted);
    final box = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: col.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, color: col, size: size * 0.55),
    );
    if (!(it.isImage || it.isVideo || it.isAudio) || it.path.contains('/.vibe_trash/')) return box;
    if (_cache.length > 400) _cache.clear();
    final f = _cache.putIfAbsent('${it.path}:${it.time}', () => Native.fsThumb(it.path, size: 160));
    return FutureBuilder<Uint8List?>(
      future: f,
      builder: (_, s) => s.data == null
          ? box
          : ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(children: [
                Image.memory(s.data!, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
                if (it.isVideo)
                  Positioned.fill(child: Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white.withValues(alpha: 0.9), size: size * 0.45))),
              ]),
            ),
    );
  }
}

/// Text output of a command (cat, tree, df…) in the chat.
class FsTermCard extends StatelessWidget {
  final Map card; // {type: term, text, path?}
  final void Function(String path) onEdit;
  const FsTermCard({super.key, required this.card, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final path = card['path'] as String?;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxWidth: 440, maxHeight: 360),
      decoration: BoxDecoration(color: c.dark ? const Color(0xFF0E0E10) : const Color(0xFFF4F5F7), borderRadius: BorderRadius.circular(10), border: Border.all(color: c.divider)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SelectableText('${card['text']}',
                style: TextStyle(color: c.text, fontFamily: 'monospace', fontSize: 12.5, height: 1.35)),
          ),
        ),
        Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: c.divider))),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(children: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '${card['text']}'));
                _snack(context, 'Copied');
              },
              icon: Icon(Icons.copy_rounded, size: 16, color: c.muted),
              label: Text('Copy', style: TextStyle(color: c.muted)),
            ),
            if (path != null) ...[
              TextButton.icon(
                onPressed: () => onEdit(path),
                icon: Icon(Icons.edit_note_rounded, size: 18, color: VC.blurple),
                label: Text('Edit', style: TextStyle(color: VC.blurple)),
              ),
              TextButton.icon(
                onPressed: () => Native.fsShare([path]),
                icon: Icon(Icons.share_rounded, size: 16, color: c.muted),
                label: Text('Share', style: TextStyle(color: c.muted)),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

// =====================================================================================
// Editor
// =====================================================================================

class FileEditorPage extends StatefulWidget {
  final String path;
  const FileEditorPage({super.key, required this.path});
  @override
  State<FileEditorPage> createState() => _FileEditorPageState();
}

class _FileEditorPageState extends State<FileEditorPage> {
  final _ctl = TextEditingController();
  String _saved = '';
  bool _loading = true, _readOnly = false, _saving = false;
  String _error = '';

  bool get _dirty => !_loading && !_readOnly && _ctl.text != _saved;
  String get _name => widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    _load();
    _ctl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  Future<void> _load() async {
    final r = await Native.fsRead(widget.path, max: 2 << 20);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r['error'] != null && r['text'] == null) {
        // A new file
        _error = r['error'] == 'missing' ? '' : '${r['error']}';
        _saved = '';
      } else {
        _saved = '${r['text'] ?? ''}';
        _ctl.text = _saved;
        _readOnly = r['truncated'] == true;
      }
    });
  }

  Future<bool> _save() async {
    setState(() => _saving = true);
    final ok = await Native.fsWrite(widget.path, _ctl.text);
    if (!mounted) return ok;
    setState(() {
      _saving = false;
      if (ok) _saved = _ctl.text;
    });
    _snack(context, ok ? 'Saved' : 'Couldn\'t save. Is "All files access" on?');
    return ok;
  }

  Future<void> _leave() async {
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final c = VC.of(context);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.pane,
        title: Text('Save changes?', style: TextStyle(color: c.text)),
        content: Text('"$_name" has unsaved changes.', style: TextStyle(color: c.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard', style: TextStyle(color: VC.red))),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (!mounted || r == null) return;
    if (r == 'save' && !await _save()) return;
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final lines = '\n'.allMatches(_ctl.text).length + 1;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: c.chat,
        appBar: AppBar(
          backgroundColor: c.pane,
          foregroundColor: c.text,
          elevation: 0,
          titleSpacing: 0,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_dirty ? '● ' : ''}$_name', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.text, fontWeight: FontWeight.w800, fontSize: 17)),
            Text(Fs.rel(Fs.parentOf(widget.path)), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.faint, fontSize: 12)),
          ]),
          actions: [
            IconButton(
              tooltip: 'Save',
              icon: _saving
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: VC.blurple))
                  : Icon(Icons.save_rounded, color: _dirty ? VC.blurple : c.faint),
              onPressed: _dirty && !_saving ? _save : null,
            ),
            PopupMenuButton<String>(
              color: c.pane,
              icon: Icon(Icons.more_vert_rounded, color: c.muted),
              onSelected: (v) async {
                if (v == 'open') {
                  final r = await Native.fsOpen(widget.path);
                  if (r != 'ok' && context.mounted) _snack(context, 'No other app opens this file.');
                }
                if (v == 'share') await Native.fsShare([widget.path]);
                if (v == 'copy') {
                  await Clipboard.setData(ClipboardData(text: _ctl.text));
                  if (context.mounted) _snack(context, 'Copied all text');
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'open', child: Text('Open with another app', style: TextStyle(color: c.text))),
                PopupMenuItem(value: 'share', child: Text('Share file', style: TextStyle(color: c.text))),
                PopupMenuItem(value: 'copy', child: Text('Copy all text', style: TextStyle(color: c.text))),
              ],
            ),
          ],
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: VC.blurple))
            : Column(children: [
                if (_readOnly)
                  Container(
                    width: double.infinity,
                    color: VC.yellow.withValues(alpha: 0.15),
                    padding: const EdgeInsets.all(10),
                    child: Text('This file is too big to edit here (over 2 MB). Showing the start, read-only.',
                        style: TextStyle(color: c.text, fontSize: 13)),
                  ),
                if (_error.isNotEmpty)
                  Padding(padding: const EdgeInsets.all(10), child: Text(_error, style: const TextStyle(color: VC.red))),
                Expanded(
                  child: TextField(
                    controller: _ctl,
                    readOnly: _readOnly,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: TextStyle(color: c.text, fontFamily: 'monospace', fontSize: 14, height: 1.4),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      hintText: 'Empty file. Start typing…',
                      hintStyle: TextStyle(color: c.faint),
                    ),
                  ),
                ),
                Container(
                  color: c.pane,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: SafeArea(
                    top: false,
                    child: Row(children: [
                      Text('$lines lines · ${_ctl.text.length} characters', style: TextStyle(color: c.faint, fontSize: 12)),
                      const Spacer(),
                      Text(_readOnly ? 'Read-only' : _dirty ? 'Not saved' : 'Saved',
                          style: TextStyle(color: _dirty ? VC.yellow : c.faint, fontSize: 12, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ]),
      ),
    );
  }
}

// =====================================================================================
// Running commands
// =====================================================================================

/// Runs file commands typed in the chat. Replies go through [say]; the pane shows lists.
class FsRunner {
  final void Function(String text, {Map? card, bool error}) say;
  final void Function(String path, String name) scan;
  final void Function(String path) edit;
  final bool Function(String name) isApp; // an app with this name (so "open music" opens the app)
  FsRunner({required this.say, required this.scan, required this.edit, required this.isApp});

  static Map get _note => {'type': 'fsnote'}; // keeps file names out of what the AI sees

  void _out(String text, {Map? card, bool error = false}) => say(text, card: card ?? _note, error: error);

  Future<bool> run(String text) async {
    final cmd = FsCmd.parse(text);
    if (cmd == null) return false;
    // "open music" with an app called Music: let the app open
    if (cmd.natural && !cmd.explicit && cmd.op == 'open' && isApp(cmd.args.first)) return false;
    await Fs.init();
    if (!Fs.access && !await Fs.checkAccess()) {
      if (cmd.natural && !cmd.explicit) return false;
      _out('To work with your files, Vibe needs "All files access".', card: {
        'type': 'ask',
        'state': 'ask',
        'buttons': [
          {'label': 'Allow all files access', 'do': 'fsperm', 'primary': true},
        ],
      });
      return true;
    }
    try {
      return await _run(cmd);
    } catch (e) {
      _out('That file command failed: $e', error: true);
      return true;
    }
  }

  String _a(FsCmd c, [int i = 0]) => i < c.args.length ? c.args[i] : '';
  String _flags(FsCmd c) => '${c.o['flags'] ?? ''}';

  /// A file by path or name: right here first, then anywhere on the phone.
  /// Returns the path, or null after telling you what happened (pane shows choices when there are several).
  Future<String?> _pick(String name, {required String verb, bool dirsOk = true, bool quietMissing = false}) async {
    final exactOnly = verb == 'rm';
    final here = await Fs.resolve(name, fuzzy: !exactOnly, useAliases: !exactOnly);
    if (here != null) {
      if (!dirsOk && await Fs.kind(here) == 'dir') {
        _out('$verb: "${Fs.nameOf(here)}" is a folder.', error: true);
        return null;
      }
      return here;
    }
    if (name.contains('/')) {
      if (!quietMissing) _out('$verb: no such file or folder: $name', error: true);
      return null;
    }
    final found = await Fs.lookup(name, fuzzy: !exactOnly);
    if (found.isEmpty) {
      if (!quietMissing) _out('$verb: I couldn\'t find "$name" anywhere on your phone.', error: true);
      return null;
    }
    final exact = found.where((f) => f.name.toLowerCase() == Fs.unquote(name).toLowerCase()).toList();
    if (exact.length == 1) return exact.first.path;
    if (found.length == 1 && verb != 'rm') return found.first.path;
    FsPane.i.showResults('Which "$name"?', '${found.length} files · tap ⋮ for options', found);
    _out('I found ${found.length} files like "$name". Pick one in the list (⋮ for share, delete, edit…).');
    return null;
  }

  Future<bool> _run(FsCmd c) async {
    final p = FsPane.i;
    switch (c.op) {
      case 'help': {
          _out(fsHelp);
          return true;

      }
      case 'pwd': {
          _out('`${Fs.rel(Fs.cwd)}`\n${Fs.cwd}');
          return true;

      }
      case 'cd': {
          final arg = _a(c).isEmpty ? '~' : _a(c);
          final to = await Fs.resolve(arg);
          if (to == null) {
            _out('cd: no such folder: $arg', error: true);
            return true;
          }
          if (await Fs.kind(to) != 'dir') {
            _out('cd: not a folder: ${Fs.nameOf(to)}', error: true);
            return true;
          }
          await p.openDir(to);
          return true;

      }
      case 'ls': {
          final f = _flags(c);
          final arg = c.args.isEmpty ? '.' : c.args.join(' ');
          if (arg.contains('*')) {
            final hits = await Fs.expand(arg);
            final items = <FsItem>[];
            for (final h in hits) {
              final i = await Fs.info(h);
              if (i != null) items.add(i);
            }
            p.showResults('ls $arg', '${items.length} matches', items);
            return true;
          }
          final to = await Fs.resolve(arg);
          if (to == null) {
            _out('ls: cannot access \'$arg\': no such file or folder', error: true);
            return true;
          }
          if (await Fs.kind(to) == 'file') {
            final i = await Fs.info(to);
            if (i != null) p.showResults(i.name, Fs.rel(Fs.parentOf(to)), [i]);
            return true;
          }
          await p.openDir(to, sortBy: f.contains('t') ? 'time' : f.contains('S') ? 'size' : 'name', showHidden: f.contains('a'));
          if (f.contains('r')) p.setSort(p.sort);
          return true;

      }
      case 'open': {
          final arg = _a(c);
          String? to = await Fs.resolve(arg);
          if (to == null) {
            if (c.natural && !c.explicit) return false;
            to = await _pick(arg, verb: 'open');
            if (to == null) return true;
          }
          if (await Fs.kind(to) == 'dir') {
            await p.openDir(to);
          } else {
            final r = await Native.fsOpen(to);
            if (r == 'apk') _out('To install ${Fs.nameOf(to)}, open it from your Files app (Vibe doesn\'t install apps).');
            if (r == 'noapp') _out('No app on your phone opens ${Fs.nameOf(to)}.', card: {'type': 'ask', 'state': 'ask', 'path': to, 'buttons': [{'label': 'Share it', 'do': 'fsshare'}]});
          }
          return true;

      }
      case 'find': {
          return _find(c);

      }
      case 'grep': {
          final ci = !_flags(c).contains('s');
          final pattern = c.args.first;
          final where = c.args.length > 1 ? await Fs.resolve(c.args.sublist(1).join(' ')) : Fs.cwd;
          if (where == null) {
            _out('grep: no such file or folder: ${c.args.sublist(1).join(' ')}', error: true);
            return true;
          }
          p.busy('Lines with "$pattern"');
          final r = await Native.fsGrep(where, pattern, caseSensitive: !ci);
          final items = [for (final m in (r['items'] as List?) ?? const []) FsItem.fromMap(m as Map)];
          p.showResults('Lines with "$pattern"', '${items.length} matches in ${Fs.rel(where)}', items, part: r['partial'] == true);
          return true;

      }
      case 'du': {
          final where = await Fs.resolve(c.args.isEmpty ? '.' : c.args.join(' '));
          if (where == null) {
            _out('du: no such folder', error: true);
            return true;
          }
          p.busy('Space used in ${Fs.nameOf(where)}');
          final r = await Native.fsDu(where);
          final items = [for (final m in (r['items'] as List?) ?? const []) FsItem.fromMap(m as Map)];
          p.showResults('Space used in ${Fs.nameOf(where)}', '${fsSize((r['total'] as num?)?.toInt() ?? 0)} total · biggest first', items,
              bySize: true, part: r['partial'] == true);
          return true;

      }
      case 'df': {
          final vols = await Native.fsDf();
          final lines = [
            for (final v in vols)
              '${v['path'] == Fs.root ? 'Phone' : 'SD card'}: ${fsSize((v['free'] as num).toInt())} free of ${fsSize((v['total'] as num).toInt())} '
                  '(${(100 - (v['free'] as num) * 100 / ((v['total'] as num) == 0 ? 1 : (v['total'] as num))).round()}% used)',
          ];
          _out('💾 ${lines.join('\n')}');
          return true;

      }
      case 'cat' || 'head' || 'tail' || 'wc': {
          final path = await _pick(_a(c), verb: c.op, dirsOk: false);
          if (path == null) return true;
          final it = await Fs.info(path);
          if (it != null && !it.isText) {
            _out('${c.op}: ${it.name} isn\'t a text file.', card: {'type': 'ask', 'state': 'ask', 'path': path, 'buttons': [{'label': 'Open it', 'do': 'fsopen', 'primary': true}]});
            return true;
          }
          final r = await Native.fsRead(path, max: c.op == 'wc' ? 8 << 20 : 256 * 1024);
          if (r['text'] == null) {
            _out('${c.op}: couldn\'t read ${Fs.nameOf(path)}', error: true);
            return true;
          }
          var text = '${r['text']}';
          if (c.op == 'wc') {
            final lines = '\n'.allMatches(text).length + (text.isEmpty || text.endsWith('\n') ? 0 : 1);
            final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
            _out('`${Fs.nameOf(path)}`: $lines lines · $words words · ${text.length} characters');
            return true;
          }
          final n = (c.o['n'] as int?) ?? 10;
          final ls = text.split('\n');
          if (c.op == 'head') text = ls.take(n).join('\n');
          if (c.op == 'tail') text = ls.skip(ls.length > n ? ls.length - n : 0).join('\n');
          if (text.length > 6000) text = '${text.substring(0, 6000)}\n… (open the editor to see it all)';
          say('📄 ${Fs.nameOf(path)}', card: {'type': 'term', 'text': text.isEmpty ? '(empty file)' : text, 'path': path});
          return true;

      }
      case 'edit': {
          var path = await Fs.resolve(_a(c));
          if (path == null) {
            if (c.o['create'] == true) {
              path = await Fs.resolve(_a(c), create: true);
            } else {
              path = await _pick(_a(c), verb: 'edit', dirsOk: false);
            }
            if (path == null) return true;
          }
          if (await Fs.kind(path) == 'dir') {
            _out('edit: ${Fs.nameOf(path)} is a folder.', error: true);
            return true;
          }
          final it = await Fs.info(path);
          if (it != null && !it.isText) {
            _out('${it.name} isn\'t a text file, so it can\'t be edited here.', card: {'type': 'ask', 'state': 'ask', 'path': path, 'buttons': [{'label': 'Open with an app', 'do': 'fsopen', 'primary': true}]});
            return true;
          }
          edit(path);
          return true;

      }
      case 'touch' || 'mkdir': {
          final made = <String>[];
          var target = c.o['in'] != null ? await Fs.resolve('${c.o['in']}') : Fs.cwd;
          target ??= Fs.cwd;
          for (final a in c.args) {
            final saved = Fs.cwd;
            Fs.cwd = target;
            final dest = await Fs.resolve(a, create: true);
            Fs.cwd = saved;
            if (dest == null) continue;
            final r = await Native.fsOp(c.op, dest: dest);
            if ('${r['error']}'.isEmpty) {
              made.add(dest);
            } else {
              _out('${c.op}: ${r['error'] == 'exists' ? '"$a" already exists' : 'couldn\'t create "$a"'}', error: true);
            }
          }
          if (made.isEmpty) return true;
          _out('✓ Created ${made.map(Fs.nameOf).join(', ')} in ${Fs.rel(Fs.parentOf(made.first))}');
          if (p.open && p.mode == 'dir') {
            await p.refresh();
          } else {
            await p.openDir(Fs.parentOf(made.first));
          }
          if (c.op == 'touch' && c.o['edit'] == true && made.length == 1) edit(made.first);
          return true;

      }
      case 'rm': {
          final paths = <String>[];
          for (final a in c.args) {
            final hits = await Fs.expand(a, fuzzy: false);
            if (hits.isEmpty && !a.contains('*')) {
              final one = await _pick(a, verb: 'rm', quietMissing: c.natural && !c.explicit);
              if (one == null) {
                if (c.natural && !c.explicit && FsPane.i.title != 'Which "$a"?') return false;
                continue;
              }
              hits.add(one);
            }
            paths.addAll(hits);
          }
          if (paths.isEmpty) return true;
          if (!_flags(c).contains('r')) {
            for (final x in paths) {
              if (await Fs.kind(x) == 'dir') {
                _out('rm: "${Fs.nameOf(x)}" is a folder. Use rm -r to remove folders.', error: true);
                return true;
              }
            }
          }
          if (paths.any((x) => Fs.volumes.contains(x))) {
            _out('rm: I won\'t delete your whole storage.', error: true);
            return true;
          }
          // Main folders (Download, DCIM, Pictures, Android…) stay; delete what's inside instead
          final top = <String>[];
          for (final x in paths) {
            if (x != Fs.parentOf(x) && Fs.volumes.contains(Fs.parentOf(x)) && await Fs.kind(x) == 'dir') top.add(x);
          }
          if (top.isNotEmpty && !(!c.natural && _flags(c).contains('f'))) {
            _out('rm: I won\'t delete the main "${Fs.nameOf(top.first)}" folder. Delete the files inside it instead'
                '${c.natural ? '' : ' (or use rm -rf if you really mean it)'}.', error: true);
            return true;
          }
          final r = await Native.fsOp('trash', paths: paths);
          final done = List<String>.from((r['done'] as List?) ?? const []);
          if (done.isEmpty) {
            _out('rm: couldn\'t delete ${paths.map(Fs.nameOf).join(', ')}', error: true);
            return true;
          }
          _out('🗑️ Moved ${done.length == 1 ? Fs.nameOf(paths.first) : '${done.length} items'} to trash.', card: {
            'type': 'ask',
            'state': 'ask',
            'paths': done,
            'buttons': [
              {'label': 'Undo', 'do': 'fsundo'},
              {'label': 'Open trash', 'do': 'fstrash'},
            ],
          });
          if (p.open) {
            if (p.mode == 'results') p.items.removeWhere((e) => paths.contains(e.path));
            await p.refresh();
          }
          return true;

      }
      case 'mv' || 'cp' || 'rename': {
          if (c.op == 'rename') {
            final src = await _pick(_a(c), verb: 'rename');
            if (src == null) return true;
            final r = await Native.fsOp('rename', paths: [src], name: _a(c, 1));
            _out('${r['error']}'.isEmpty ? '✓ Renamed to ${_a(c, 1)}' : 'rename: ${r['error'] == 'exists' ? '"${_a(c, 1)}" already exists' : 'couldn\'t rename'}',
                error: '${r['error']}'.isNotEmpty);
            if (p.open) await p.refresh();
            return true;
          }
          final destArg = c.args.last;
          final srcs = <String>[];
          for (final a in c.args.sublist(0, c.args.length - 1)) {
            final hits = await Fs.expand(a);
            if (hits.isEmpty) {
              final one = await _pick(a, verb: c.op);
              if (one == null) return true;
              hits.add(one);
            }
            srcs.addAll(hits);
          }
          final dest = await Fs.resolve(destArg) ?? await Fs.resolve(destArg, create: true);
          if (dest == null) {
            _out('${c.op}: bad destination: $destArg', error: true);
            return true;
          }
          final r = await Native.fsOp(c.op == 'mv' ? 'move' : 'copy', paths: srcs, dest: dest);
          final done = (r['done'] as List?)?.length ?? 0;
          final verb = c.op == 'mv' ? 'Moved' : 'Copied';
          _out(done == 0
              ? '${c.op}: ${r['error']}'
              : '✓ $verb ${done == 1 ? Fs.nameOf(srcs.first) : '$done items'} to ${Fs.rel(await Fs.kind(dest) == 'dir' ? dest : Fs.parentOf(dest))}'
                  '${'${r['error']}'.isNotEmpty ? ' (some failed: ${r['error']})' : ''}',
              error: done == 0);
          if (p.open) await p.refresh();
          return true;

      }
      case 'share': {
          final paths = <String>[];
          if (c.o['latest'] != null) {
            final k = '${c.o['latest']}';
            final s = _specFrom(k);
            final dl = k == 'download' ? await Fs.resolve('downloads') : null;
            final plain = k == 'download' || k == 'file';
            final r = await Native.fsFind(
                root: dl ?? Fs.root, like: plain ? null : s.like, mime: plain ? null : s.mime, exts: plain ? const [] : s.exts, limit: 1);
            final l = (r['items'] as List?) ?? const [];
            if (l.isEmpty) {
              _out('I couldn\'t find a recent $k.', error: true);
              return true;
            }
            paths.add(FsItem.fromMap(l.first as Map).path);
          } else {
            for (final a in c.args) {
              final hits = await Fs.expand(a);
              if (hits.isEmpty) {
                final one = await _pick(a, verb: 'share', dirsOk: false);
                if (one == null) return true;
                hits.add(one);
              }
              paths.addAll(hits);
            }
          }
          final files = <String>[];
          for (final x in paths) {
            if (await Fs.kind(x) == 'file') files.add(x);
          }
          if (files.isEmpty) {
            _out('share: nothing to share (folders can\'t be shared; share the files inside).', error: true);
            return true;
          }
          if (!await Native.fsShare(files)) _out('Couldn\'t open the share sheet.', error: true);
          return true;

      }
      case 'tree': {
          final where = await Fs.resolve(c.args.isEmpty ? '.' : c.args.join(' '));
          if (where == null) {
            _out('tree: no such folder', error: true);
            return true;
          }
          final depth = ((c.o['n'] as int?) ?? 2).clamp(1, 4);
          final out = StringBuffer('${Fs.rel(where)}\n');
          var lines = 0;
          Future<void> walk(String dir, String pre, int d) async {
            final kids = (await Fs.list(dir, hidden: false) ?? const <FsItem>[]).toList()
              ..sort((a, b) => a.dir != b.dir ? (a.dir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
            for (var i = 0; i < kids.length; i++) {
              if (lines > 200) return;
              final last = i == kids.length - 1;
              out.writeln('$pre${last ? '└── ' : '├── '}${kids[i].name}${kids[i].dir ? '/' : ''}');
              lines++;
              if (kids[i].dir && d < depth) await walk(kids[i].path, '$pre${last ? '    ' : '│   '}', d + 1);
            }
          }

          await walk(where, '', 1);
          if (lines > 200) out.writeln('… (more)');
          say('🌳 ${Fs.nameOf(where)}', card: {'type': 'term', 'text': out.toString().trimRight()});
          return true;

      }
      case 'stat': {
          final path = await _pick(_a(c), verb: 'stat');
          if (path == null) return true;
          final it = await Fs.info(path);
          if (it == null) return true;
          _out([
            '**${it.name}**',
            'Where: ${Fs.rel(Fs.parentOf(path))}',
            it.dir ? 'Folder · ${it.count} items' : 'Size: ${fsSize(it.size)} (${it.size} bytes)',
            if (!it.dir) 'Type: ${it.mime}',
            'Changed: ${fsDate(it.time)}',
          ].join('\n'));
          return true;

      }
      case 'echo': {
          final path = await Fs.resolve(_a(c), create: true);
          if (path == null) return true;
          final append = c.o['append'] == true;
          final ok = await Native.fsWrite(path, '${c.o['text']}\n', append: append);
          _out(ok ? '✓ ${append ? 'Added to' : 'Wrote'} ${Fs.nameOf(path)}' : 'echo: couldn\'t write ${Fs.nameOf(path)}', error: !ok);
          if (p.open) await p.refresh();
          return true;

      }
      case 'trash': {
          await p.showTrash();
          return true;

      }
      case 'emptytrash': {
          final n = (await Native.fsTrash()).length;
          if (n == 0) {
            _out('The trash is already empty.');
            return true;
          }
          _out('Empty the trash? $n ${n == 1 ? 'item is' : 'items are'} deleted for good.', card: {
            'type': 'ask',
            'state': 'ask',
            'buttons': [
              {'label': 'Empty trash', 'do': 'fsemptytrash', 'primary': true},
              {'label': 'Cancel', 'do': 'cancelfs'},
            ],
          });
          return true;

      }
      case 'restore': {
          final name = Fs.unquote(_a(c)).toLowerCase();
          final all = [for (final m in await Native.fsTrash()) FsItem.fromMap(m)];
          final hits = all.where((e) => e.name.toLowerCase() == name).toList();
          final some = hits.isNotEmpty ? hits : all.where((e) => e.name.toLowerCase().contains(name)).toList();
          if (some.isEmpty) {
            if (c.natural && !c.explicit && !name.contains('.')) return false;
            _out('restore: "${_a(c)}" isn\'t in the trash.', error: true);
            return true;
          }
          if (some.length > 1) {
            await p.showTrash();
            _out('Several things in the trash match "${_a(c)}". Pick one in the list.');
            return true;
          }
          final r = await Native.fsOp('restore', paths: [some.first.path]);
          final done = (r['done'] as List?) ?? const [];
          _out(done.isEmpty ? 'restore: couldn\'t bring it back' : '↩️ Restored ${some.first.name} to ${Fs.rel(Fs.parentOf('${done.first}'))}',
              error: done.isEmpty);
          if (p.open) await p.refresh();
          return true;
      }
    }
    return false;
  }

  Future<bool> _find(FsCmd c) async {
    final p = FsPane.i;
    String title;
    String? like, mime;
    var exts = <String>[];
    var newer = (c.o['newer'] as int?) ?? 0, older = (c.o['older'] as int?) ?? 0;
    var min = (c.o['min'] as int?) ?? 0;
    final max = (c.o['max'] as int?) ?? 0;
    var bySize = c.o['big'] == true;
    var root = Fs.cwd;
    final dirs = c.o['dirs'] == true;
    if (c.o['words'] != null) {
      final s = _specFrom('${c.o['words']}');
      like = s.like;
      mime = s.mime;
      exts = s.exts;
      newer = s.newer;
      older = s.older;
      min = s.min;
      bySize = s.bySize;
      title = s.title;
      root = Fs.root;
      if (s.inArg != null) {
        final r = await Fs.resolve(s.inArg!);
        if (r == null) {
          // "in" wasn't a folder after all: part of the name
          final s2 = _specFrom('${c.o['words']}'.replaceAll(RegExp(r'\b(?:in|inside|under|from)\b', caseSensitive: false), ' '));
          like = s2.like;
          title = s2.title;
        } else {
          root = r;
          title = '$title in ${Fs.nameOf(r)}';
        }
      }
      if (like == null && mime == null && exts.isEmpty && newer == 0 && min == 0) return false;
    } else if (c.o['recent'] == true) {
      newer = DateTime.now().millisecondsSinceEpoch - 30 * 86400000;
      root = c.o['in'] != null ? (await Fs.resolve('${c.o['in']}') ?? Fs.root) : Fs.root;
      title = root == Fs.root ? 'Recent files' : 'Recent in ${Fs.nameOf(root)}';
    } else if (c.o['big'] == true) {
      min = 100 << 20;
      root = Fs.root;
      title = 'Big files (over 100 MB)';
    } else {
      final name = c.o['name'] as String?;
      if (name != null) {
        final n = Fs.unquote(name);
        like = n.contains('*') || n.contains('?') ? n.replaceAll('*', '%').replaceAll('?', '_') : (n.contains('.') ? '%$n%' : '%${n.replaceAll(' ', '%')}%');
      }
      if (c.args.isNotEmpty) {
        final r = await Fs.resolve(c.args.join(' '));
        if (r == null) {
          _out('find: no such folder: ${c.args.join(' ')}', error: true);
          return true;
        }
        root = r;
      } else if (c.o['name'] != null && c.o.length == 1) {
        root = Fs.root; // "find resume": the whole phone
      }
      title = [
        if (name != null) '"${Fs.unquote(name)}"' else dirs ? 'Folders' : 'Files',
        'in ${Fs.nameOf(root)}',
      ].join(' ');
    }
    p.busy(title);
    final r = await Native.fsFind(
        root: root, like: like, mime: mime, exts: exts, min: min, max: max, newer: newer, older: older, dirs: dirs, limit: 300);
    final items = [for (final m in (r['items'] as List?) ?? const []) FsItem.fromMap(m as Map)];
    p.showResults(title, '${items.length}${items.length >= 300 ? '+' : ''} found · ${bySize ? 'biggest' : 'newest'} first', items,
        bySize: bySize, part: r['partial'] == true);
    if (items.isEmpty) _out('Nothing found for $title.');
    return true;
  }

  /// Buttons on file messages (Undo, Open trash…). True when handled.
  Future<bool> onAsk(String action, Map card) async {
    switch (action) {
      case 'fsperm': {
          await Native.requestFiles();
      }
      case 'fsundo': {
          final r = await Native.fsOp('restore', paths: List<String>.from((card['paths'] as List?) ?? const []));
          final n = (r['done'] as List?)?.length ?? 0;
          _out(n == 0 ? 'Couldn\'t undo.' : '↩️ Restored ${n == 1 ? 'it' : '$n items'}.', error: n == 0);
          if (FsPane.i.open) await FsPane.i.refresh();
      }
      case 'fstrash': {
          await FsPane.i.showTrash();
      }
      case 'fsemptytrash': {
          final r = await Native.fsOp('emptyTrash');
          _out('🗑️ Trash emptied (${(r['done'] as List?)?.length ?? 0} items deleted for good).');
          if (FsPane.i.open && FsPane.i.mode == 'trash') await FsPane.i.refresh();
      }
      case 'cancelfs': {
          break;
      }
      case 'fsopen': {
          final r = await Native.fsOpen('${card['path']}');
          if (r == 'noapp') _out('No app on your phone opens this kind of file.');
          if (r == 'apk') _out('To install it, open it from your Files app.');
      }
      case 'fsshare': {
          await Native.fsShare(['${card['path']}']);
      }
      case 'fsedit': {
          edit('${card['path']}');
      }
      default: {
          return false;
      }
    }
    return true;
  }
}

const fsHelp = '**Files in Vibe**\n'
    '• Linux: `ls`, `ls -lt`, `cd Download`, `cd ..`, `cd /`, `cd -`, `pwd`, `find *.pdf`, `find -size +100M`, `find -mtime -7`, '
    '`locate resume`, `grep "booking id" Documents`, `du`, `df`, `tree`, `cat notes.txt`, `head -n 20 log.txt`, `wc`, `stat`, '
    '`nano todo.txt`, `touch a.txt`, `mkdir Projects`, `mv a.pdf Documents`, `cp *.jpg Pictures`, `rm movie.mp3`, `rm -r OldFolder`, '
    '`echo "hi" > note.txt`, `share *.pdf`, `open report.pdf`\n'
    '• Plain words: "list the files in downloads", "open whatsapp folder", "search file named resume", "pdfs from today", '
    '"photos from yesterday", "big files", "share movie.mp3", "share the last screenshot", "delete movie.mp3", "edit text.html", '
    '"rename a.txt to b.txt", "move movie.mp3 to music", "create folder Projects", "show trash", "restore movie.mp3", "empty trash"\n'
    '• Deleting moves things to the trash (kept 30 days), so you can undo. Names don\'t need exact case: `cd vibe tel` works.';
