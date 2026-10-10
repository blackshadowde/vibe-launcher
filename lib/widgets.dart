import 'package:flutter/material.dart';
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
        decoration: const BoxDecoration(color: VC.blurple, shape: BoxShape.circle),
        child: Icon(Icons.bolt_rounded, color: Colors.white, size: size * 0.6),
      );
}

Widget appIcon(AppEntry a, double size) => ClipOval(
      child: Image.memory(a.icon,
          width: size, height: size, gaplessPlayback: true, filterQuality: FilterQuality.medium),
    );

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
    return Container(
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
    );
  }
}

/// Long-press menu for an app.
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
        const SizedBox(height: 12),
        item(Icons.open_in_new_rounded, 'Open', () { Navigator.pop(ctx); onOpen(); }),
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
Widget richText(String text, VC c, {bool error = false}) {
  final base = TextStyle(color: error ? VC.red : c.text, fontSize: 16, height: 1.35);
  final lines = text.replaceAll('\r', '').split('\n');
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
                    decoration: const BoxDecoration(color: VC.blurple, shape: BoxShape.circle),
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
