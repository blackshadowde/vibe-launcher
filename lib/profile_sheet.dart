import 'package:flutter/material.dart';
import 'widgets.dart';
import 'launcher.dart';
import 'settings_page.dart';
import 'theme.dart';

/// Tap your name in the bottom bar: your profile + phone info + Manage account.
void showProfileSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ProfileSheet(),
  );
}

class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet();
  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  Map _info = {};

  @override
  void initState() {
    super.initState();
    Native.deviceInfo().then((m) { if (mounted) setState(() => _info = m); });
  }

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: prefs.name == 'You' ? '' : prefs.name);
    final c = VC.of(context);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Display name', style: TextStyle(color: c.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: c.text),
          decoration: const InputDecoration(hintText: 'Your name'),
          onSubmitted: (t) => Navigator.pop(ctx, t),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (v != null) setState(() => prefs.setName(v));
  }

  String _gb(num? b) => b == null ? '–' : '${(b / 1e9).toStringAsFixed(b > 1e11 ? 0 : 1)} GB';

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final total = (_info['storageTotal'] as num?)?.toDouble();
    final free = (_info['storageFree'] as num?)?.toDouble();
    final used = (total != null && free != null) ? total - free : null;
    final battery = _info['battery'] as int?;
    final charging = _info['charging'] == true;

    return Container(
      decoration: BoxDecoration(
        color: c.chat,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Banner + avatar
          SizedBox(
            height: 150,
            child: Stack(clipBehavior: Clip.none, children: [
              Container(height: 100, color: VC.blurple),
              Positioned(
                top: 8, right: 8,
                child: _circleBtn(Icons.edit_rounded, _editName),
              ),
              Positioned(
                left: 16, top: 52,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: c.chat, shape: BoxShape.circle),
                  child: Avatar(name: prefs.name, size: 84),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(prefs.name,
                style: TextStyle(color: c.text, fontSize: 22, fontWeight: FontWeight.w800)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
            child: Text(
                _info.isEmpty ? '' : '${_info['maker']} ${_info['model']}',
                style: TextStyle(color: c.muted, fontSize: 14)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: VC.blurple, minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  icon: const Icon(Icons.manage_accounts_rounded),
                  label: const Text('Account'),
                  onPressed: () { prefs.tap(); Native.openAccounts(); },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: c.pane, foregroundColor: c.text, minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Vibe settings'),
                  onPressed: () {
                    prefs.tap();
                    final nav = Navigator.of(context);
                    nav.pop();
                    nav.push(MaterialPageRoute(builder: (_) => const SettingsPage()));
                  },
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          _card(c, [
            _label(c, 'PHONE'),
            _row(c, Icons.phone_android_rounded, 'Model', _info.isEmpty ? '–' : '${_info['maker']} ${_info['model']}'),
            _row(c, Icons.android_rounded, 'Android', _info['android']?.toString() ?? '–'),
            _row(c, charging ? Icons.battery_charging_full_rounded : Icons.battery_std_rounded,
                'Battery', battery == null ? '–' : '$battery%${charging ? ' · charging' : ''}'),
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.storage_rounded, color: c.muted, size: 20),
              const SizedBox(width: 12),
              Text('Storage', style: TextStyle(color: c.text, fontSize: 15)),
              const Spacer(),
              Text('${_gb(used)} of ${_gb(total)}', style: TextStyle(color: c.muted, fontSize: 14)),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (used != null && total != null && total > 0) ? used / total : 0,
                minHeight: 8,
                backgroundColor: c.divider,
                color: (used != null && total != null && used / total > 0.9) ? VC.red : VC.blurple,
              ),
            ),
          ]),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }

  Widget _circleBtn(IconData i, VoidCallback onTap) => Material(
        color: Colors.black38,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(8), child: Icon(i, color: Colors.white, size: 20)),
        ),
      );

  Widget _card(VC c, List<Widget> kids) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids),
      );

  Widget _label(VC c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: TextStyle(color: c.faint, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      );

  Widget _row(VC c, IconData i, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(i, color: c.muted, size: 20),
          const SizedBox(width: 12),
          Text(k, style: TextStyle(color: c.text, fontSize: 15)),
          const Spacer(),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.muted, fontSize: 14)),
          ),
        ]),
      );
}
