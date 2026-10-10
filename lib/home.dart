import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'launcher.dart';
import 'main.dart';
import 'profile_sheet.dart';
import 'settings_page.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<AppEntry> _apps = [];
  bool _loading = true;
  bool _isDefault = true;
  int _server = -1; // -1 = all apps, otherwise index in [categories]
  String _query = '';
  final _search = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.onHomePressed = _goHome;
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
    if (s == AppLifecycleState.paused) _clearSearch();
  }

  Future<void> _refresh() async {
    final list = await Native.apps();
    final def = await Native.isDefault();
    if (!mounted) return;
    setState(() {
      _apps = list;
      _isDefault = def;
      _loading = false;
    });
  }

  void _goHome() {
    navKey.currentState?.popUntil((r) => r.isFirst);
    _clearSearch();
    setState(() => _server = -1);
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _clearSearch() {
    _search.clear();
    _focus.unfocus();
    if (_query.isNotEmpty) setState(() => _query = '');
  }

  bool _inServer(AppEntry a, int s) => s == -1 || categories[s].codes.contains(a.category);

  List<AppEntry> get _visible {
    final q = _query.trim().toLowerCase();
    final list = _apps.where((a) {
      if (prefs.hidden.contains(a.pkg)) return false;
      if (q.isNotEmpty) return a.label.toLowerCase().contains(q);
      return _inServer(a, _server);
    }).toList();
    int byName(AppEntry a, AppEntry b) => a.label.toLowerCase().compareTo(b.label.toLowerCase());
    if (prefs.sort == SortMode.az || q.isNotEmpty) {
      list.sort(byName);
    } else {
      list.sort((a, b) {
        final d = (prefs.lastUsed[b.pkg] ?? 0).compareTo(prefs.lastUsed[a.pkg] ?? 0);
        return d != 0 ? d : byName(a, b);
      });
    }
    return list;
  }

  Future<void> _launch(AppEntry a) async {
    prefs.tap();
    prefs.markUsed(a.pkg);
    await Native.launch(a.pkg);
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: (c.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
        child: PopScope(
          canPop: false, // Back never closes the launcher
          onPopInvokedWithResult: (_, __) => _goHome(),
          child: Scaffold(
            backgroundColor: c.rail,
            body: SafeArea(
              bottom: false,
              child: Column(children: [
                Expanded(
                  child: Row(children: [
                    _rail(c),
                    Expanded(child: _pane(c)),
                  ]),
                ),
                _UserBar(onChanged: () => setState(() {})),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- left rail ("servers") ----------
  Widget _rail(VC c) {
    final used = <int>[
      for (var i = 0; i < categories.length; i++)
        if (_apps.any((a) => !prefs.hidden.contains(a.pkg) && _inServer(a, i))) i
    ];
    return SizedBox(
      width: 72,
      child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 8), children: [
        _ServerIcon(
          selected: _server == -1 && _query.isEmpty,
          color: VC.blurple,
          tooltip: 'All apps',
          onTap: () { prefs.tap(); _clearSearch(); setState(() => _server = -1); },
          child: const Icon(Icons.apps_rounded, color: Colors.white, size: 26),
        ),
        Center(
          child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              width: 32, height: 2,
              decoration: BoxDecoration(color: c.divider, borderRadius: BorderRadius.circular(1))),
        ),
        for (final i in used)
          _ServerIcon(
            selected: _server == i && _query.isEmpty,
            color: c.chat,
            tooltip: categories[i].name,
            onTap: () { prefs.tap(); _clearSearch(); setState(() => _server = i); },
            child: Icon(categories[i].icon,
                color: _server == i ? VC.blurple : c.muted, size: 24),
          ),
      ]),
    );
  }

  // ---------- middle pane (DM list) ----------
  Widget _pane(VC c) {
    final list = _visible;
    final title = _query.isNotEmpty
        ? 'Search'
        : _server == -1 ? 'Apps' : categories[_server].name;
    return Container(
      decoration: BoxDecoration(
        color: c.pane,
        borderRadius: const BorderRadius.only(topLeft: Radius.circular(16)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Row(children: [
            Text(title,
                style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Text('${list.length}', style: TextStyle(color: c.faint, fontSize: 14)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: SizedBox(
            height: 38,
            child: TextField(
              controller: _search,
              focusNode: _focus,
              onChanged: (v) => setState(() => _query = v),
              onSubmitted: (_) { if (list.isNotEmpty) _launch(list.first); _clearSearch(); },
              textInputAction: TextInputAction.go,
              style: TextStyle(color: c.text, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Find an app',
                hintStyle: TextStyle(color: c.faint),
                prefixIcon: Icon(Icons.search_rounded, color: c.faint, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close_rounded, color: c.muted, size: 18),
                        onPressed: _clearSearch),
                filled: true,
                fillColor: c.input,
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
            ),
          ),
        ),
        if (!_isDefault && !_loading) _defaultBanner(c),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: VC.blurple))
              : list.isEmpty
                  ? Center(child: Text('No apps here', style: TextStyle(color: c.faint)))
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _AppRow(
                        app: list[i],
                        onTap: () => _launch(list[i]),
                        onLongPress: () => _appMenu(list[i]),
                      ),
                    ),
        ),
      ]),
    );
  }

  Widget _defaultBanner(VC c) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(color: VC.blurple, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          const Expanded(
            child: Text('Make Vibe your Home app',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            style: TextButton.styleFrom(
                backgroundColor: Colors.white, foregroundColor: VC.blurple,
                minimumSize: const Size(0, 32)),
            onPressed: Native.openHomeSettings,
            child: const Text('Set'),
          ),
        ]),
      );

  void _appMenu(AppEntry a) {
    prefs.heavy();
    final c = VC.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const SizedBox(width: 20),
            ClipOval(child: Image.memory(a.icon, width: 48, height: 48, gaplessPlayback: true)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.label,
                    style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w700)),
                Text(a.pkg, style: TextStyle(color: c.faint, fontSize: 12),
                    overflow: TextOverflow.ellipsis),
              ]),
            ),
            const SizedBox(width: 20),
          ]),
          const SizedBox(height: 12),
          _menuItem(c, Icons.open_in_new_rounded, 'Open', () { Navigator.pop(ctx); _launch(a); }),
          _menuItem(c, Icons.info_outline_rounded, 'App info',
              () { Navigator.pop(ctx); Native.appInfo(a.pkg); }),
          _menuItem(c, Icons.visibility_off_outlined, 'Hide from list',
              () { Navigator.pop(ctx); prefs.toggleHidden(a.pkg); }),
          _menuItem(c, Icons.delete_outline_rounded, 'Uninstall',
              () { Navigator.pop(ctx); Native.uninstall(a.pkg); }, danger: true),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _menuItem(VC c, IconData icon, String label, VoidCallback onTap, {bool danger = false}) {
    final col = danger ? VC.red : c.text;
    return ListTile(
      leading: Icon(icon, color: col),
      title: Text(label, style: TextStyle(color: col, fontWeight: FontWeight.w500)),
      onTap: onTap,
    );
  }
}

/// Discord server icon: circle that turns into a rounded square, with the white pill.
class _ServerIcon extends StatelessWidget {
  final bool selected;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final Widget child;
  const _ServerIcon({required this.selected, required this.color, required this.tooltip,
      required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 4,
          height: selected ? 40 : 0,
          decoration: BoxDecoration(
            color: c.text,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: tooltip,
          child: GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: selected && color != VC.blurple ? c.card : color,
                borderRadius: BorderRadius.circular(selected ? 16 : 24),
              ),
              child: Center(child: child),
            ),
          ),
        ),
      ]),
    );
  }
}

/// One app shown as a DM row.
class _AppRow extends StatelessWidget {
  final AppEntry app;
  final VoidCallback onTap, onLongPress;
  const _AppRow({required this.app, required this.onTap, required this.onLongPress});

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
              ClipOval(
                child: Image.memory(app.icon,
                    width: 42, height: 42, gaplessPlayback: true, filterQuality: FilterQuality.medium),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(app.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.text, fontSize: 16, fontWeight: FontWeight.w600)),
                  if (sub.isNotEmpty)
                    Text(sub, style: TextStyle(color: c.faint, fontSize: 13)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Bottom user panel: your profile + settings gear.
class _UserBar extends StatelessWidget {
  final VoidCallback onChanged;
  const _UserBar({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return Container(
      color: c.card,
      padding: EdgeInsets.fromLTRB(8, 6, 8, 6 + MediaQuery.of(context).padding.bottom),
      child: Row(children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () { prefs.tap(); showProfileSheet(context); },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(children: [
                Avatar(name: prefs.name, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(prefs.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 14)),
                    Text('Online', style: TextStyle(color: c.muted, fontSize: 12)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
        // Tap = phone settings, long-press = launcher settings
        GestureDetector(
          onTap: () { prefs.tap(); Native.openSettings(); },
          onLongPress: () {
            prefs.heavy();
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
          },
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(Icons.settings_rounded, color: c.muted, size: 24),
          ),
        ),
      ]),
    );
  }
}

/// Round avatar with initial and green online dot.
class Avatar extends StatelessWidget {
  final String name;
  final double size;
  final bool dot;
  const Avatar({super.key, required this.name, this.size = 40, this.dot = true});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final d = size * 0.34;
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
              width: d + 4,
              height: d + 4,
              decoration: BoxDecoration(color: c.card, shape: BoxShape.circle),
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
