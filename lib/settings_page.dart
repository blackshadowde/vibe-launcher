import 'package:flutter/material.dart';
import 'gemini.dart';
import 'launcher.dart';
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
                  context, MaterialPageRoute(builder: (_) => const _HiddenAppsPage())),
            ),
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
              onTap: () => _editText(context, 'Gemini model', prefs.geminiModel, prefs.setGeminiModel,
                  hint: Gemini.defaultModel),
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
              subtitle: Text('Version 0.3.0', style: TextStyle(color: c.faint)),
            ),
          ]),
        ]),
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

class _HiddenAppsPage extends StatefulWidget {
  const _HiddenAppsPage();
  @override
  State<_HiddenAppsPage> createState() => _HiddenAppsPageState();
}

class _HiddenAppsPageState extends State<_HiddenAppsPage> {
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
        appBar: AppBar(backgroundColor: c.chat, title: const Text('Hidden apps')),
        body: ListView.builder(
          itemCount: _apps.length,
          itemBuilder: (_, i) {
            final a = _apps[i];
            return SwitchListTile(
              secondary: ClipOval(child: Image.memory(a.icon, width: 36, height: 36)),
              title: Text(a.label, style: TextStyle(color: c.text)),
              value: prefs.hidden.contains(a.pkg),
              onChanged: (_) => prefs.toggleHidden(a.pkg),
            );
          },
        ),
      ),
    );
  }
}
