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
