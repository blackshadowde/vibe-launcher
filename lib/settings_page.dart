import 'package:flutter/material.dart';
import 'gemini.dart';
import 'launcher.dart';
import 'people.dart';
import 'theme.dart';

/// Long-press the gear: launcher settings.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => Scaffold(
        backgroundColor: c.chat,
        appBar: AppBar(
          backgroundColor: c.chat,
          title: const Text('Launcher settings', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          _section(c, 'APPEARANCE'),
          _group(c, [
            _radio(c, 'Dark', prefs.theme == ThemeMode.dark, () => prefs.setTheme(ThemeMode.dark)),
            _radio(c, 'Light', prefs.theme == ThemeMode.light, () => prefs.setTheme(ThemeMode.light)),
            _radio(c, 'Follow system', prefs.theme == ThemeMode.system,
                () => prefs.setTheme(ThemeMode.system)),
          ]),
          _section(c, 'APPS'),
          _group(c, [
            _radio(c, 'Sort by recently opened', prefs.sort == SortMode.recent,
                () => prefs.setSort(SortMode.recent)),
            _radio(c, 'Sort A–Z', prefs.sort == SortMode.az, () => prefs.setSort(SortMode.az)),
            ListTile(
              leading: Icon(Icons.visibility_off_outlined, color: c.muted),
              title: Text('Hidden apps', style: TextStyle(color: c.text)),
              subtitle: Text('${prefs.hidden.length} hidden', style: TextStyle(color: c.faint)),
              trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const _AppTogglePage(muted: false))),
            ),
          ]),
          _section(c, 'NOTIFICATIONS'),
          _group(c, [
            FutureBuilder<bool>(
              future: Native.notifAccess(),
              builder: (_, snap) {
                final ok = snap.data == true;
                return ListTile(
                  leading: Icon(Icons.notifications_active_outlined, color: c.muted),
                  title: Text('Notification access', style: TextStyle(color: c.text)),
                  subtitle: Text(ok ? 'Allowed' : 'Not allowed: tap to allow',
                      style: TextStyle(color: ok ? VC.green : VC.yellow)),
                  trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
                  onTap: Native.openNotifAccess,
                );
              },
            ),
            SwitchListTile(
              title: Text('Show notifications in chat', style: TextStyle(color: c.text)),
              subtitle: Text('Each app\'s notifications appear as its messages',
                  style: TextStyle(color: c.faint)),
              value: prefs.showNotifs,
              onChanged: prefs.setShowNotifs,
            ),
            SwitchListTile(
              title: Text('Music updates', style: TextStyle(color: c.text)),
              subtitle: Text('"Playing…", "Paused…" and song changes, with controls',
                  style: TextStyle(color: c.faint)),
              value: prefs.showMedia,
              onChanged: prefs.setShowMedia,
            ),
            SwitchListTile(
              title: Text('Let Vibe AI read them', style: TextStyle(color: c.text)),
              subtitle: Text('For "what did I miss?" and replies. Sends recent notifications to Gemini',
                  style: TextStyle(color: c.faint)),
              value: prefs.aiNotifs,
              onChanged: prefs.setAiNotifs,
            ),
            ListTile(
              leading: Icon(Icons.notifications_off_outlined, color: c.muted),
              title: Text('Muted apps', style: TextStyle(color: c.text)),
              subtitle: Text('${prefs.muted.length} muted', style: TextStyle(color: c.faint)),
              trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const _AppTogglePage(muted: true))),
            ),
          ]),
          _section(c, 'PEOPLE'),
          _group(c, [
            FutureBuilder<Map>(
              future: Native.peoplePerms(),
              builder: (_, snap) {
                final m = snap.data ?? {};
                final all = m.isNotEmpty && m.values.every((v) => v == true);
                final missing = [
                  if (m['contacts'] != true) 'contacts',
                  if (m['calls'] != true) 'call log',
                  if (m['phone'] != true) 'calls',
                  if (m['sms'] != true) 'SMS',
                ];
                return ListTile(
                  leading: Icon(Icons.contacts_rounded, color: c.muted),
                  title: Text('Contacts, calls & SMS', style: TextStyle(color: c.text)),
                  subtitle: Text(all ? 'Allowed' : 'Not allowed: ${missing.join(', ')}. Tap to allow',
                      style: TextStyle(color: all ? VC.green : VC.yellow)),
                  trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
                  onTap: () async {
                    await People.ensure();
                    prefs.refresh();
                  },
                );
              },
            ),
            _radio(c, '"Message someone" uses WhatsApp', prefs.messenger == 'whatsapp',
                () => prefs.setMessenger('whatsapp')),
            _radio(c, '"Message someone" uses SMS', prefs.messenger == 'sms', () => prefs.setMessenger('sms')),
          ]),
          _section(c, 'VIBE AI (GEMINI)'),
          _group(c, [
            ListTile(
              leading: Icon(Icons.key_rounded, color: c.muted),
              title: Text('Gemini API key', style: TextStyle(color: c.text)),
              subtitle: Text(
                  prefs.geminiKey.isEmpty
                      ? 'Not set: Vibe only opens apps'
                      : 'Set (…${prefs.geminiKey.substring(prefs.geminiKey.length - 4)}). Stored only on this phone',
                  style: TextStyle(color: prefs.geminiKey.isEmpty ? VC.yellow : c.faint)),
              trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
              onTap: () => _editText(context, 'Gemini API key', prefs.geminiKey, prefs.setGeminiKey,
                  hint: 'Paste your key', secret: true),
            ),
            ListTile(
              leading: Icon(Icons.open_in_new_rounded, color: c.muted),
              title: Text('Get a free key', style: TextStyle(color: c.text)),
              subtitle: Text('Google AI Studio → Get API key', style: TextStyle(color: c.faint)),
              onTap: () => Native.openUrl('https://aistudio.google.com/apikey'),
            ),
            ListTile(
              leading: Icon(Icons.memory_rounded, color: c.muted),
              title: Text('Model', style: TextStyle(color: c.text)),
              subtitle: Text(prefs.geminiModel.isEmpty ? '${Gemini.defaultModel} (default)' : prefs.geminiModel,
                  style: TextStyle(color: c.faint)),
              trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
              onTap: () => _pickModel(context),
            ),
            if (prefs.geminiKey.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.key_off_rounded, color: VC.red),
                title: const Text('Remove API key', style: TextStyle(color: VC.red)),
                subtitle: Text('Vibe goes back to opening apps only', style: TextStyle(color: c.faint)),
                onTap: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('Remove Gemini key?', style: TextStyle(color: c.text)),
                      content: Text('It will be deleted from this phone.', style: TextStyle(color: c.muted)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: VC.red),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) prefs.setGeminiKey('');
                },
              ),
          ]),
          _section(c, 'FEEL'),
          _group(c, [
            SwitchListTile(
              title: Text('Haptics', style: TextStyle(color: c.text)),
              subtitle: Text('Light vibration on taps', style: TextStyle(color: c.faint)),
              value: prefs.haptics,
              onChanged: prefs.setHaptics,
            ),
          ]),
          _section(c, 'PHONE'),
          _group(c, [
            ListTile(
              leading: Icon(Icons.home_rounded, color: c.muted),
              title: Text('Choose Home app', style: TextStyle(color: c.text)),
              subtitle: Text('Switch between Vibe and your old launcher',
                  style: TextStyle(color: c.faint)),
              onTap: Native.openHomeSettings,
            ),
          ]),
          _section(c, 'ABOUT'),
          _group(c, [
            ListTile(
              leading: Icon(Icons.info_outline_rounded, color: c.muted),
              title: Text('Vibe Launcher', style: TextStyle(color: c.text)),
              subtitle: Text('Version 0.8.0', style: TextStyle(color: c.faint)),
            ),
          ]),
        ]),
      ),
    );
  }

  /// Bottom sheet listing the models your key can use.
  void _pickModel(BuildContext context) {
    final c = VC.of(context);
    if (prefs.geminiKey.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Add your Gemini API key first')));
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: FutureBuilder<List<({String id, String label})>?>(
          future: Gemini.listModels(),
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator(color: VC.blurple));
            }
            final list = snap.data;
            Widget tile(String id, String label, String sub) {
              final on = (prefs.geminiModel.isEmpty ? Gemini.defaultModel : prefs.geminiModel) == id;
              return ListTile(
                title: Text(label, style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
                subtitle: Text(sub, style: TextStyle(color: c.faint, fontSize: 12)),
                trailing: Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: on ? VC.blurple : c.faint),
                onTap: () {
                  prefs.setGeminiModel(id == Gemini.defaultModel ? '' : id);
                  Navigator.pop(ctx);
                },
              );
            }

            return ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Choose a Gemini model',
                    style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Flash-Lite is fastest. "latest" models update by themselves.',
                    style: TextStyle(color: c.muted, fontSize: 13)),
              ),
              tile(Gemini.defaultModel, 'Default', '${Gemini.defaultModel} · always the newest Flash'),
              if (list == null)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Couldn\'t load the model list. Check your key and connection.',
                      style: TextStyle(color: VC.red)),
                )
              else
                for (final m in list.where((m) => m.id != Gemini.defaultModel)) tile(m.id, m.label, m.id),
              const SizedBox(height: 16),
            ]);
          },
        ),
      ),
    );
  }

  Future<void> _editText(BuildContext context, String title, String value, void Function(String) save,
      {String hint = '', bool secret = false}) async {
    final c = VC.of(context);
    final ctrl = TextEditingController(text: value);
    var hide = secret;
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(title, style: TextStyle(color: c.text)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            obscureText: hide,
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(color: c.text),
            decoration: InputDecoration(
              hintText: hint,
              suffixIcon: secret
                  ? IconButton(
                      icon: Icon(hide ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                      onPressed: () => set(() => hide = !hide))
                  : null,
            ),
          ),
          actions: [
            if (value.isNotEmpty)
              TextButton(
                  onPressed: () => Navigator.pop(ctx, ''),
                  child: const Text('Clear', style: TextStyle(color: VC.red))),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (v != null) save(v);
  }

  Widget _section(VC c, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(t,
            style: TextStyle(color: c.faint, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      );

  Widget _group(VC c, List<Widget> kids) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: kids),
      );

  Widget _radio(VC c, String label, bool on, VoidCallback onTap) => ListTile(
        title: Text(label, style: TextStyle(color: c.text)),
        trailing: Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            color: on ? VC.blurple : c.faint),
        onTap: () { prefs.tap(); onTap(); },
      );
}

/// Hidden apps or muted apps: one switch per app.
class _AppTogglePage extends StatefulWidget {
  final bool muted;
  const _AppTogglePage({required this.muted});
  @override
  State<_AppTogglePage> createState() => _AppTogglePageState();
}

class _AppTogglePageState extends State<_AppTogglePage> {
  List<AppEntry> _apps = [];

  @override
  void initState() {
    super.initState();
    Native.apps().then((l) {
      l.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      if (mounted) setState(() => _apps = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => Scaffold(
        backgroundColor: c.chat,
        appBar: AppBar(backgroundColor: c.chat, title: Text(widget.muted ? 'Muted apps' : 'Hidden apps')),
        body: ListView.builder(
          itemCount: _apps.length,
          itemBuilder: (_, i) {
            final a = _apps[i];
            return SwitchListTile(
              secondary: ClipOval(child: Image.memory(a.icon, width: 36, height: 36)),
              title: Text(a.label, style: TextStyle(color: c.text)),
              value: widget.muted ? prefs.muted.contains(a.pkg) : prefs.hidden.contains(a.pkg),
              onChanged: (_) => widget.muted ? prefs.toggleMuted(a.pkg) : prefs.toggleHidden(a.pkg),
            );
          },
        ),
      ),
    );
  }
}
