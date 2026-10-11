import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'launcher.dart';
import 'theme.dart';

/// Your round avatar with initial and green online dot.
class Avatar extends StatelessWidget {
  final String name;
  final double size;
  final bool dot;
  final Color? ring;
  const Avatar({super.key, required this.name, this.size = 40, this.dot = true, this.ring});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final d = size * 0.3;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        CircleAvatar(
          radius: size / 2,
          backgroundColor: VC.blurple,
          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: TextStyle(color: Colors.white, fontSize: size * 0.42, fontWeight: FontWeight.w700)),
        ),
        if (dot)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: d + 5,
              height: d + 5,
              decoration: BoxDecoration(color: ring ?? c.chat, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Container(
                  width: d, height: d,
                  decoration: const BoxDecoration(color: VC.green, shape: BoxShape.circle)),
            ),
          ),
      ]),
    );
  }
}

/// Vibe's own avatar in the chat.
class BotAvatar extends StatelessWidget {
  final double size;
  const BotAvatar({super.key, this.size = 40});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: VC.blurple, shape: BoxShape.circle),
        child: Icon(Icons.bolt_rounded, color: Colors.white, size: size * 0.6),
      );
}

/// App icon: round by default, or the icon's own shape (better with icon packs).
Widget appIcon(AppEntry a, double size) {
  final img = Image.memory(a.icon, width: size, height: size, gaplessPlayback: true, filterQuality: FilterQuality.medium);
  return prefs.roundIcons ? ClipOval(child: img) : img;
}

/// One app as a DM row (used in the slide-in app list).
class AppRow extends StatelessWidget {
  final AppEntry app;
  final VoidCallback onTap, onLongPress;
  const AppRow({super.key, required this.app, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final sub = ago(prefs.lastUsed[app.pkg]);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(children: [
              appIcon(app, 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(app.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.text, fontSize: 16, fontWeight: FontWeight.w600)),
                  if (sub.isNotEmpty) Text(sub, style: TextStyle(color: c.faint, fontSize: 13)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Card under a Vibe reply: icon, name, Open button.
class AppCard extends StatelessWidget {
  final AppEntry app;
  final VoidCallback onOpen, onLongPress;
  const AppCard({super.key, required this.app, required this.onOpen, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return Pressable(
        child: Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: c.pane,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.divider),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onOpen,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(children: [
              appIcon(app, 36),
              const SizedBox(width: 10),
              Expanded(
                child: Text(app.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 15)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: VC.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                onPressed: onOpen,
                child: const Text('Open'),
              ),
            ]),
          ),
        ),
      ),
    ));
  }
}

/// Long-press menu for an app.
/// Set by the home screen: "Scan with VirusTotal" in the app menu.
void Function(AppEntry)? onScanApp;

void showAppMenu(BuildContext context, AppEntry a, VoidCallback onOpen) {
  prefs.heavy();
  final c = VC.of(context);
  Widget item(IconData icon, String label, VoidCallback onTap, {bool danger = false}) {
    final col = danger ? VC.red : c.text;
    return ListTile(
      leading: Icon(icon, color: col),
      title: Text(label, style: TextStyle(color: col, fontWeight: FontWeight.w500)),
      onTap: onTap,
    );
  }

  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const SizedBox(width: 20),
          appIcon(a, 48),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.label, style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w700)),
              Text(a.pkg, style: TextStyle(color: c.faint, fontSize: 12), overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 20),
        ]),
        const SizedBox(height: 8),
        // The app's own shortcuts (e.g. Chrome → New incognito tab), when Vibe is the Home app
        FutureBuilder<List<Map>?>(
          future: Native.shortcuts(pkg: a.pkg),
          builder: (_, snap) {
            final list = snap.data ?? const [];
            if (list.isEmpty) return const SizedBox.shrink();
            return Column(children: [
              for (final sc in list.take(5))
                ListTile(
                  dense: true,
                  leading: SizedBox(
                    width: 28,
                    height: 28,
                    child: FutureBuilder<Uint8List?>(
                      future: Native.shortcutIcon(a.pkg, '${sc['id']}'),
                      builder: (_, i) => i.data == null
                          ? Icon(Icons.bolt_rounded, color: c.muted)
                          : Image.memory(i.data!, width: 28, height: 28),
                    ),
                  ),
                  title: Text('${sc['label']}', style: TextStyle(color: c.text, fontWeight: FontWeight.w500)),
                  onTap: () {
                    Navigator.pop(ctx);
                    Native.startShortcut(a.pkg, '${sc['id']}');
                  },
                ),
              Divider(height: 8, color: c.divider),
            ]);
          },
        ),
        item(Icons.open_in_new_rounded, 'Open', () { Navigator.pop(ctx); onOpen(); }),
        if (onScanApp != null)
          item(Icons.shield_outlined, 'Scan with VirusTotal', () { Navigator.pop(ctx); onScanApp!(a); }),
        item(Icons.info_outline_rounded, 'App info', () { Navigator.pop(ctx); Native.appInfo(a.pkg); }),
        item(Icons.visibility_off_outlined, 'Hide from list',
            () { Navigator.pop(ctx); prefs.toggleHidden(a.pkg); }),
        item(Icons.delete_outline_rounded, 'Uninstall',
            () { Navigator.pop(ctx); Native.uninstall(a.pkg); }, danger: true),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

/// Light Markdown for Gemini replies: **bold**, *italic*, `code`, bullets and headings.
Widget richText(String text, VC c, {bool error = false, void Function(String url)? onScan}) =>
    RichMsg(text: text, error: error, onScan: onScan);

/// A link found in a message: kind is url / email / phone.
class MsgLink {
  final String kind, value, label;
  const MsgLink(this.kind, this.value, this.label);
}

const linkBlue = Color(0xFF00A8FC);

final _linkRe = RegExp(
    r'\[([^\]\n]+)\]\(((?:https?://|www\.)[^\s)]+)\)' // 1-2: [text](url)
    r'|((?:https?://|www\.)[^\s<>"]*[^\s<>"' "'" r'.,;:!?)\]*])' // 3: bare link
    r'|([\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[a-z]{2,})' // 4: email
    r'|((?<![\w+/=.-])(?:\+\d{1,3}[\s-]?\d[\d\s-]{6,12}\d|(?:0)?[6-9]\d{4}[\s-]?\d{5})(?![\w/=-]))', // 5: phone
    caseSensitive: false);

String _fullUrl(String u) => u.toLowerCase().startsWith('www.') ? 'https://$u' : u;

/// Every link, email and phone number in a text, in order, without repeats.
List<MsgLink> findLinks(String text) {
  final out = <MsgLink>[];
  final seen = <String>{};
  for (final m in _linkRe.allMatches(text)) {
    MsgLink l;
    if (m.group(2) != null) {
      l = MsgLink('url', _fullUrl(m.group(2)!), m.group(1)!);
    } else if (m.group(3) != null) {
      l = MsgLink('url', _fullUrl(m.group(3)!), m.group(3)!);
    } else if (m.group(4) != null) {
      l = MsgLink('email', m.group(4)!, m.group(4)!);
    } else {
      l = MsgLink('phone', m.group(5)!.replaceAll(RegExp(r'[\s-]'), ''), m.group(5)!);
    }
    if (seen.add('${l.kind}:${l.value}')) out.add(l);
  }
  return out;
}

/// Opens what a tap on a link means: websites open, emails go to your mail app, numbers ask what to do.
void openLink(BuildContext context, MsgLink l) {
  prefs.tap();
  switch (l.kind) {
    case 'url':
      Native.openUrl(l.value);
    case 'email':
      Native.openUrl('mailto:${l.value}');
    default:
      showPhoneSheet(context, l.value);
  }
}

Future<void> _messageNumber(String n) async {
  if (prefs.messenger == 'whatsapp' && await Native.whatsapp(n, '')) return;
  await Native.smsApp(n, '');
}

Widget _sheetRow(VC c, IconData icon, String label, VoidCallback onTap, {Color? color}) => ListTile(
      leading: Icon(icon, color: color ?? c.muted),
      title: Text(label, style: TextStyle(color: color ?? c.text, fontWeight: FontWeight.w600)),
      onTap: () {
        prefs.tap();
        onTap();
      },
    );

void _copied(BuildContext context) => ScaffoldMessenger.maybeOf(context)
    ?.showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));

void showPhoneSheet(BuildContext context, String number) {
  final c = VC.of(context);
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    backgroundColor: c.chat,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(number, style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w800)),
        ),
        _sheetRow(c, Icons.call_rounded, 'Call', () {
          Navigator.pop(ctx);
          Native.call(number);
        }, color: VC.green),
        _sheetRow(c, Icons.chat_bubble_outline_rounded, 'Message', () {
          Navigator.pop(ctx);
          _messageNumber(number);
        }),
        _sheetRow(c, Icons.person_add_alt_1_rounded, 'Save contact', () {
          Navigator.pop(ctx);
          Native.addContact(number);
        }),
        _sheetRow(c, Icons.copy_rounded, 'Copy', () {
          Navigator.pop(ctx);
          Clipboard.setData(ClipboardData(text: number));
          _copied(context);
        }),
      ]),
    ),
  );
}

/// Long-press on a message with links: copy the message, or open / copy / share / scan each link.
void showMessageMenu(BuildContext context, String text, {void Function(String url)? onScan}) {
  final c = VC.of(context);
  final links = findLinks(text);
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: c.chat,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          _sheetRow(c, Icons.copy_rounded, 'Copy message', () {
            Navigator.pop(ctx);
            Clipboard.setData(ClipboardData(text: text));
            _copied(context);
          }),
          for (final l in links) ...[
            Divider(height: 1, color: c.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Text(l.label, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: linkBlue, fontWeight: FontWeight.w700)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                ActionChip(
                  avatar: Icon(l.kind == 'phone' ? Icons.call_rounded : l.kind == 'email' ? Icons.mail_outline_rounded : Icons.open_in_new_rounded,
                      size: 16, color: c.text),
                  label: Text(l.kind == 'phone' ? 'Call' : l.kind == 'email' ? 'Email' : 'Open'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    if (l.kind == 'phone') {
                      Native.call(l.value);
                    } else {
                      openLink(context, l);
                    }
                  },
                ),
                ActionChip(
                  avatar: Icon(Icons.copy_rounded, size: 16, color: c.text),
                  label: const Text('Copy'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: l.value));
                    _copied(context);
                  },
                ),
                ActionChip(
                  avatar: Icon(Icons.share_rounded, size: 16, color: c.text),
                  label: const Text('Share'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Native.shareText(l.value);
                  },
                ),
                if (l.kind == 'url' && onScan != null)
                  ActionChip(
                    avatar: Icon(Icons.shield_outlined, size: 16, color: c.text),
                    label: const Text('Scan with VirusTotal'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      onScan(l.value);
                    },
                  ),
              ]),
            ),
          ],
        ]),
      ),
    ),
  );
}

/// Message text with **bold**, *italic*, `code`, # headings, • lists, and tappable links,
/// emails and phone numbers.
class RichMsg extends StatefulWidget {
  final String text;
  final bool error;
  final void Function(String url)? onScan;
  const RichMsg({super.key, required this.text, this.error = false, this.onScan});
  @override
  State<RichMsg> createState() => _RichMsgState();
}

class _RichMsgState extends State<RichMsg> {
  final _recs = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recs) {
      r.dispose();
    }
    _recs.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final c = VC.of(context);
    final base = TextStyle(color: widget.error ? VC.red : c.text, fontSize: 16, height: 1.35);
    final lines = widget.text.replaceAll('\r', '').split('\n');
    final spans = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var style = base;
      final h = RegExp(r'^#{1,6}\s+').firstMatch(line);
      if (h != null) {
        line = line.substring(h.end);
        style = base.copyWith(fontWeight: FontWeight.w800);
      }
      final b = RegExp(r'^(\s*)[*\-•]\s+').firstMatch(line);
      if (b != null) line = '${b.group(1)}•  ${line.substring(b.end)}';
      spans.addAll(_inline(line, style, c));
      if (i < lines.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return Text.rich(TextSpan(children: spans));
  }

  List<InlineSpan> _inline(String s, TextStyle style, VC c) {
    final out = <InlineSpan>[];
    // Links first, so a * or _ inside a web address isn't read as formatting
    var last = 0;
    for (final m in _linkRe.allMatches(s)) {
      var before = s.substring(last, m.start);
      var end = m.end;
      var st = style;
      // **[menu](https://…)** → a bold link
      if (before.endsWith('**') && s.startsWith('**', m.end)) {
        before = before.substring(0, before.length - 2);
        end = m.end + 2;
        st = style.copyWith(fontWeight: FontWeight.w800);
      }
      if (before.isNotEmpty) out.addAll(_format(before, style, c));
      final l = findLinks(m.group(0)!).firstOrNull;
      if (l == null) {
        out.add(TextSpan(text: m.group(0), style: st));
      } else {
        final rec = TapGestureRecognizer()..onTap = () => openLink(context, l);
        _recs.add(rec);
        out.add(TextSpan(
          text: l.kind == 'url' && m.group(1) != null ? m.group(1) : m.group(0),
          style: st.copyWith(color: linkBlue),
          recognizer: rec,
        ));
      }
      last = end;
    }
    if (last < s.length) out.addAll(_format(s.substring(last), style, c));
    return out;
  }

  List<InlineSpan> _format(String s, TextStyle style, VC c) {
    final out = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) out.add(TextSpan(text: s.substring(last, m.start), style: style));
      if (m.group(1) != null) {
        out.add(TextSpan(text: m.group(1), style: style.copyWith(fontWeight: FontWeight.w800)));
      } else if (m.group(2) != null) {
        out.add(TextSpan(
            text: m.group(2),
            style: style.copyWith(fontFamily: 'monospace', backgroundColor: c.card, fontSize: 14)));
      } else {
        out.add(TextSpan(text: m.group(3), style: style.copyWith(fontStyle: FontStyle.italic)));
      }
      last = m.end;
    }
    if (last < s.length) out.add(TextSpan(text: s.substring(last), style: style));
    return out;
  }
}

/// Source links under a search answer.
Widget linkChips(List<Map> links, VC c) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (var i = 0; i < links.length; i++)
          Material(
            color: c.pane,
            shape: StadiumBorder(side: BorderSide(color: c.divider)),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => Native.openUrl((links[i]['u'] ?? '').toString()),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: VC.blurple, shape: BoxShape.circle),
                    child: Text('${i + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text((links[i]['t'] ?? 'Source').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );

/// Three bouncing dots while Vibe is thinking.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key});
  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return AnimatedBuilder(
      animation: _a,
      builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Transform.translate(
            offset: Offset(0, -3 * _bounce((_a.value - i * 0.15) % 1.0)),
            child: Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(color: c.muted, shape: BoxShape.circle),
            ),
          ),
      ]),
    );
  }

  double _bounce(double t) => t < 0.3 ? (t / 0.3) : t < 0.6 ? (1 - (t - 0.3) / 0.3) : 0;
}

/// Discord-style swipe-to-reply (same feel as Vibe): swipe a message left, a blurple
/// reply circle grows in on the right and pops with a buzz; let go to reply.
/// Swipes to the right are handed to [onPassUpdate]/[onPassEnd] (the app list).
class SwipeReply extends StatefulWidget {
  final Widget child;
  final VoidCallback? onReply; // null = can't reply to this one
  final GestureDragUpdateCallback? onPassUpdate;
  final GestureDragEndCallback? onPassEnd;
  const SwipeReply({super.key, required this.child, this.onReply, this.onPassUpdate, this.onPassEnd});

  @override
  State<SwipeReply> createState() => _SwipeReplyState();
}

class _SwipeReplyState extends State<SwipeReply> with SingleTickerProviderStateMixin {
  static const _threshold = 72.0, _maxDrag = 110.0;
  late final AnimationController _back =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  double _dx = 0, _from = 0;
  bool _armed = false;
  bool? _passing; // decided on the first movement

  @override
  void initState() {
    super.initState();
    _back.addListener(() => setState(() => _dx = _from * (1 - Curves.easeOutCubic.transform(_back.value))));
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    _passing ??= d.delta.dx > 0 || widget.onReply == null;
    if (_passing!) return widget.onPassUpdate?.call(d);
    if (_back.isAnimating) _back.stop();
    var next = _dx + d.delta.dx;
    if (next > 0) next = 0;
    if (next < -_threshold) next = _dx + d.delta.dx * 0.45; // rubber band
    next = next.clamp(-_maxDrag, 0.0);
    final armed = next <= -_threshold;
    if (armed && !_armed) prefs.heavy();
    setState(() {
      _dx = next;
      _armed = armed;
    });
  }

  void _end(DragEndDetails d) {
    final passing = _passing ?? false;
    _passing = null;
    if (passing) return widget.onPassEnd?.call(d);
    final fire = _armed;
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
    if (fire) {
      Future.delayed(const Duration(milliseconds: 140), () {
        if (mounted) widget.onReply?.call();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = (-_dx / _threshold).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: () => _end(DragEndDetails()),
      child: ClipRect(
        child: Stack(alignment: Alignment.centerRight, children: [
          if (_dx < -1)
            Positioned(
              right: 16,
              child: Opacity(
                opacity: progress,
                child: AnimatedScale(
                  scale: _armed ? 1.15 : 0.55 + 0.45 * progress,
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutBack,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: VC.blurple,
                      shape: BoxShape.circle,
                      boxShadow: _armed
                          ? [BoxShadow(color: VC.blurple.withAlpha(120), blurRadius: 10)]
                          : null,
                    ),
                    child: const Icon(Icons.reply, color: Colors.white, size: 22),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ]),
      ),
    );
  }
}

/// Discord-style reply connector: up from the avatar's top-centre, round corner, then right.
class ReplyCurve extends CustomPainter {
  final Color color;
  const ReplyCurve(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, mid = size.height / 2;
    const r = 8.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
        Path()
          ..moveTo(cx, size.height + 2)
          ..lineTo(cx, mid + r)
          ..quadraticBezierTo(cx, mid, cx + r, mid)
          ..lineTo(size.width, mid),
        paint);
  }

  @override
  bool shouldRepaint(covariant ReplyCurve old) => old.color != color;
}

/// The strip above a reply: curve, tiny avatar, @name, one-line preview.
Widget replyStrip(VC c, {required Widget avatar, required String name, required String preview}) =>
    SizedBox(
      height: 22,
      child: Row(children: [
        SizedBox(width: 40, height: 22, child: CustomPaint(painter: ReplyCurve(c.muted.withValues(alpha: 0.45)))),
        const SizedBox(width: 6),
        avatar,
        const SizedBox(width: 6),
        Flexible(
          flex: 0,
          child: Text('@$name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.text, fontSize: 13.5, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.muted, fontSize: 13.5)),
        ),
      ]),
    );

/// Google-Messages style entrance for a brand-new message (same as Vibe): the row grows
/// from the bottom so the timeline glides up, while the message rises, scales from its
/// corner and fades in. Rows that don't animate are returned untouched.
class Entrance extends StatefulWidget {
  final bool animate;
  final bool fromRight;
  final Widget child;
  const Entrance({super.key, required this.animate, this.fromRight = false, required this.child});

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  Animation<double>? _size, _pop, _fade;

  @override
  void initState() {
    super.initState();
    if (!widget.animate) return;
    final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 460));
    _c = c;
    _size = CurvedAnimation(parent: c, curve: const Interval(0.0, 0.8, curve: Curves.easeOutCubic));
    _pop = CurvedAnimation(parent: c, curve: Curves.easeOutBack);
    _fade = CurvedAnimation(parent: c, curve: const Interval(0.0, 0.55, curve: Curves.easeOut));
    c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() {});
    });
    c.forward();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || c.isCompleted) return widget.child;
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (context, child) {
        final p = _pop!.value;
        return SizeTransition(
          sizeFactor: _size!,
          axisAlignment: 1.0,
          child: Opacity(
            opacity: _fade!.value.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - p) * 38),
              child: Transform.scale(
                scale: 0.86 + 0.14 * p,
                alignment: widget.fromRight ? Alignment.bottomRight : Alignment.bottomLeft,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Fade + rise-in once, with a small per-index delay (used when the chat first opens).
class Stagger extends StatefulWidget {
  final int index;
  final int maxIndex;
  final double dy;
  final Widget child;
  const Stagger({super.key, required this.index, required this.child, this.maxIndex = 12, this.dy = 18});

  @override
  State<Stagger> createState() => _StaggerState();
}

class _StaggerState extends State<Stagger> with SingleTickerProviderStateMixin {
  late final bool _play = widget.index <= widget.maxIndex;
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 460), value: _play ? 0 : 1);
  late final Animation<double> _curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    if (_play) {
      Future<void>.delayed(Duration(milliseconds: 32 * widget.index), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _curve,
        child: widget.child,
        builder: (context, child) => _c.isCompleted
            ? child!
            : Opacity(
                opacity: _curve.value.clamp(0.0, 1.0),
                child: Transform.translate(offset: Offset(0, (1 - _curve.value) * widget.dy), child: child),
              ),
      );
}

/// Shrinks a little under your finger and springs back (taps and long-presses still work).
class Pressable extends StatefulWidget {
  final Widget child;
  final double scale;
  const Pressable({super.key, required this.child, this.scale = 0.96});

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: Duration(milliseconds: _down ? 90 : 320),
          curve: _down ? Curves.easeOut : Curves.easeOutBack,
          child: widget.child,
        ),
      );
}
