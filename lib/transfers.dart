import 'package:flutter/material.dart';
import 'launcher.dart';
import 'theme.dart';

/// Something running in the background: a download, an upload, a scan. Shown as one slim blue bar
/// in the message box instead of piling progress messages into the timeline.
class Transfer {
  final String id, title, kind; // kind: download / upload / scan / model
  int done, total; // total 0 = unknown size (bar keeps moving)
  String sub;
  final VoidCallback? cancel;
  Transfer(this.id, this.title, this.kind, {this.done = 0, this.total = 0, this.sub = '', this.cancel});

  double? get frac => total > 0 ? (done / total).clamp(0.0, 1.0) : null;

  IconData get icon => switch (kind) {
        'upload' => Icons.upload_rounded,
        'scan' => Icons.shield_outlined,
        'model' => Icons.phone_android_rounded,
        _ => Icons.download_rounded,
      };
}

class Transfers extends ChangeNotifier {
  Transfers._();
  static final Transfers i = Transfers._();
  final _all = <String, Transfer>{};
  int _tick = 0;

  List<Transfer> get list => _all.values.toList();
  bool get busy => _all.isNotEmpty;

  /// Combined progress of everything with a known size; null when nothing has a size yet.
  double? get overall {
    final sized = _all.values.where((t) => t.total > 0).toList();
    if (sized.isEmpty) return null;
    final done = sized.fold<int>(0, (a, t) => a + t.done.clamp(0, t.total));
    final total = sized.fold<int>(0, (a, t) => a + t.total);
    return total == 0 ? null : done / total;
  }

  String get summary {
    final n = _all.length;
    if (n == 0) return '';
    final kinds = _all.values.map((t) => t.kind).toSet();
    final what = kinds.length > 1
        ? '$n tasks'
        : switch (kinds.first) {
            'upload' => n == 1 ? 'Uploading' : 'Uploading $n files',
            'scan' => 'Scanning',
            'model' => 'Downloading offline AI',
            _ => n == 1 ? 'Downloading' : 'Downloading $n files',
          };
    final o = overall;
    return o == null ? what : '$what · ${(o * 100).toStringAsFixed(0)}%';
  }

  void put(String id, String title, String kind, {int done = 0, int total = 0, String sub = '', VoidCallback? cancel}) {
    final t = _all[id];
    if (t == null) {
      _all[id] = Transfer(id, title, kind, done: done, total: total, sub: sub, cancel: cancel);
      notifyListeners();
      return;
    }
    t
      ..done = done
      ..total = total
      ..sub = sub;
    // Many tiny updates a second: redraw at most ~4 times a second
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _tick > 250) {
      _tick = now;
      notifyListeners();
    }
  }

  void remove(String id) {
    if (_all.remove(id) != null) notifyListeners();
  }
}

String _size(int b) {
  if (b <= 0) return '';
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(b / 1024).toStringAsFixed(0)} KB';
}

/// Slim bar along the bottom of the message box, plus a small "45%" chip. Tap the chip for details.
class TransferBar extends StatelessWidget {
  const TransferBar({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Transfers.i,
      builder: (context, _) {
        final t = Transfers.i;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: !t.busy
              ? const SizedBox(key: ValueKey('none'), height: 0, width: double.infinity)
              : TweenAnimationBuilder<double>(
                  key: const ValueKey('bar'),
                  tween: Tween(end: t.overall ?? 0),
                  duration: const Duration(milliseconds: 400),
                  builder: (_, v, __) => LinearProgressIndicator(
                    value: t.overall == null ? null : v,
                    minHeight: 3,
                    backgroundColor: Colors.transparent,
                    color: VC.blurple,
                  ),
                ),
        );
      },
    );
  }
}

class TransferChip extends StatelessWidget {
  const TransferChip({super.key});
  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return ListenableBuilder(
      listenable: Transfers.i,
      builder: (context, _) {
        final t = Transfers.i;
        if (!t.busy) return const SizedBox.shrink();
        final o = t.overall;
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Material(
            color: VC.blurple.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                prefs.tap();
                showTransfers(context);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, value: o, color: VC.blurple, backgroundColor: c.input),
                  ),
                  const SizedBox(width: 6),
                  Text(o == null ? '${t.list.length}' : '${(o * 100).toStringAsFixed(0)}%',
                      style: TextStyle(color: VC.blurple, fontWeight: FontWeight.w700, fontSize: 12.5)),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Details of everything running: name, progress, size, cancel.
void showTransfers(BuildContext context) {
  final c = VC.of(context);
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    backgroundColor: c.chat,
    builder: (ctx) => ListenableBuilder(
      listenable: Transfers.i,
      builder: (ctx, _) {
        final list = Transfers.i.list;
        if (list.isEmpty) {
          return SizedBox(
            height: 140,
            child: Center(child: Text('All done ✓', style: TextStyle(color: c.muted, fontSize: 16, fontWeight: FontWeight.w600))),
          );
        }
        return SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(Transfers.i.summary, style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            for (final t in list)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.divider)),
                child: Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: VC.blurple, borderRadius: BorderRadius.circular(10)),
                    child: Icon(t.icon, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 14.5)),
                      const SizedBox(height: 2),
                      Text(
                          [
                            if (t.sub.isNotEmpty) t.sub,
                            if (t.kind == 'scan' && t.total > 0) '${t.done} of ${t.total}',
                            if (t.kind != 'scan' && t.total > 0) '${_size(t.done)} of ${_size(t.total)}',
                            if (t.frac != null) '${(t.frac! * 100).toStringAsFixed(0)}%',
                          ].join(' · '),
                          style: TextStyle(color: c.faint, fontSize: 12)),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(value: t.frac, minHeight: 5, backgroundColor: c.input, color: VC.blurple),
                      ),
                    ]),
                  ),
                  if (t.cancel != null)
                    IconButton(
                      tooltip: 'Cancel',
                      icon: Icon(Icons.close_rounded, color: c.muted),
                      onPressed: () {
                        prefs.tap();
                        t.cancel!();
                      },
                    ),
                ]),
              ),
          ]),
        );
      },
    ),
  );
}
