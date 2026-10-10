import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'backup.dart';
import 'mail.dart';
import 'day.dart';
import 'gemini.dart';
import 'launcher.dart';
import 'memory.dart';
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// Vibe settings, laid out like vibe-flutter: a page of cards, each opening its own page.
class SettingsPage extends StatelessWidget {
  /// Open straight on one page (e.g. 'SEARCH'), or null for the main list.
  final String? jump;
  const SettingsPage({super.key, this.jump});

  static const _pages = <(IconData, String, String, Set<String>)>[
    (Icons.contrast_rounded, 'Appearance', 'Light/dark, accent, wallpaper, icon packs & haptics', {'APPEARANCE', 'LOOK', 'FEEL'}),
    (Icons.apps_rounded, 'Apps', 'Sorting & hidden apps', {'APPS'}),
    (Icons.notifications_rounded, 'Notifications', 'Notifications in chat, music & muted apps', {'NOTIFICATIONS'}),
    (Icons.contacts_rounded, 'People', 'Contacts, calls, SMS & default messenger', {'PEOPLE'}),
    (Icons.manage_search_rounded, 'Search & mail', 'Global search, SMS & files access, Gmail', {'SEARCH'}),
    (Icons.wb_sunny_rounded, 'Daily brief', 'Brief time, city for weather & calendar', {'DAILY BRIEF'}),
    (Icons.auto_awesome_rounded, 'Vibe AI', 'On-phone AI, Gemini, backup AI & model', {'ON-PHONE AI', 'VIBE AI (GEMINI)'}),
    (Icons.shield_rounded, 'Privacy', 'What stays on your phone', {'PRIVACY'}),
    (Icons.psychology_rounded, 'Memory', 'What Vibe remembers about you', {'MEMORY'}),
    (Icons.cloud_off_rounded, 'Offline mode', 'Use no internet; answer later', {'OFFLINE MODE'}),
    (Icons.settings_backup_restore_rounded, 'Backup & restore', 'Save or bring back chat, memory & settings', {'BACKUP'}),
    (Icons.info_rounded, 'Home app & about', 'Default launcher & version', {'PHONE', 'ABOUT'}),
  ];

  static void openPage(BuildContext context, String key) {
    for (final p in _pages) {
      if (p.$4.contains(key)) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => _SubPage(title: p.$2, show: p.$4)));
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    if (jump != null) {
      for (final p in _pages) {
        if (p.$4.contains(jump)) return _page(context, p.$2, p.$4);
      }
    }
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => Scaffold(
        backgroundColor: c.chat,
        appBar: AppBar(
          backgroundColor: c.chat,
          automaticallyImplyLeading: false,
          title: const Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          actions: [
            IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
            const SizedBox(width: 8),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Text('Settings', style: TextStyle(color: c.text, fontSize: 24, fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
              child: Text('Manage your Vibe launcher & preferences', style: TextStyle(fontSize: 14, color: c.muted)),
            ),
            for (var i = 0; i < _pages.length; i++)
              Stagger(
                index: i,
                child: _SettingsCard(
                  icon: _pages[i].$1,
                  title: _pages[i].$2,
                  subtitle: _pages[i].$3,
                  iconColor: _pages[i].$2 == 'Privacy' ? VC.green : null,
                  badge: _pages[i].$2 == 'Offline mode' && prefs.offlineMode
                      ? 'On'
                      : _pages[i].$2 == 'Vibe AI' && prefs.geminiKey.isEmpty && prefs.routerKey.isEmpty
                          ? 'Set up'
                          : null,
                  badgeColor: _pages[i].$2 == 'Vibe AI' ? VC.yellow : null,
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => _SubPage(title: _pages[i].$2, show: _pages[i].$4))),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _page(BuildContext context, String title, Set<String> show) {
    final c = VC.of(context);
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => Scaffold(
        backgroundColor: c.chat,
        appBar: AppBar(
          backgroundColor: c.chat,
          title: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        ),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          if (show.contains('APPEARANCE')) ...[
          _section(c, 'APPEARANCE'),
          _group(c, [
            _radio(c, 'Dark', prefs.theme == ThemeMode.dark, () => prefs.setTheme(ThemeMode.dark)),
            _radio(c, 'Light', prefs.theme == ThemeMode.light, () => prefs.setTheme(ThemeMode.light)),
            _radio(c, 'Follow system', prefs.theme == ThemeMode.system,
                () => prefs.setTheme(ThemeMode.system)),
          ]),
          ],
          if (show.contains('APPS')) ...[
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
          ],
          if (show.contains('NOTIFICATIONS')) ...[
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
          ],
          if (show.contains('PEOPLE')) ...[
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
          ],
          if (show.contains('MEMORY')) ...[
          _section(c, 'MEMORY'),
          _group(c, [
            ListTile(
              leading: Icon(Icons.psychology_rounded, color: c.muted),
              title: Text('What Vibe remembers', style: TextStyle(color: c.text)),
              subtitle: Text('${memory.facts.length} things · stored only on this phone',
                  style: TextStyle(color: c.faint)),
              trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _MemoryPage())),
            ),
          ]),
          ],
          if (show.contains('OFFLINE MODE')) ...[
          _section(c, 'OFFLINE MODE'),
          _group(c, [
            SwitchListTile(
              title: Text('Offline mode', style: TextStyle(color: c.text)),
              subtitle: Text(
                  'Use no internet at all. Questions for Gemini wait until you turn it off'
                  '${prefs.queue.isEmpty ? '' : ' (${prefs.queue.length} waiting)'}',
                  style: TextStyle(color: c.faint)),
              value: prefs.offlineMode,
              onChanged: prefs.setOfflineMode,
            ),
          ]),
          ],
          if (show.contains('DAILY BRIEF')) ...[
          _section(c, 'DAILY BRIEF'),
          _group(c, [
            SwitchListTile(
              title: Text('Daily brief', style: TextStyle(color: c.text)),
              subtitle: Text('Weather, calendar, reminders, missed calls, messages', style: TextStyle(color: c.faint)),
              value: prefs.brief,
              onChanged: (v) {
                prefs.setBrief(v);
                if (v) Native.requestPostNotif();
                scheduleBrief();
              },
            ),
            ListTile(
              leading: Icon(Icons.wb_sunny_outlined, color: c.muted),
              title: Text('Time', style: TextStyle(color: c.text)),
              subtitle: Text(
                  TimeOfDay(hour: prefs.briefHour, minute: prefs.briefMinute).format(context),
                  style: TextStyle(color: c.faint)),
              onTap: () async {
                final t = await showTimePicker(
                    context: context, initialTime: TimeOfDay(hour: prefs.briefHour, minute: prefs.briefMinute));
                if (t == null) return;
                prefs.setBrief(prefs.brief, hour: t.hour, minute: t.minute);
                scheduleBrief();
              },
            ),
            ListTile(
              leading: Icon(Icons.location_city_rounded, color: c.muted),
              title: Text('City for weather', style: TextStyle(color: c.text)),
              subtitle: Text(prefs.city.isEmpty ? 'Not set' : prefs.city,
                  style: TextStyle(color: prefs.city.isEmpty ? VC.yellow : c.faint)),
              trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
              onTap: () => _editText(context, 'Your city', prefs.city.split(',').first, (v) async {
                if (v.trim().isEmpty) {
                  prefs.setCity('', null, null);
                  return;
                }
                final g = await Weather.geocode(v);
                if (g != null) prefs.setCity(g.$1, g.$2, g.$3);
              }, hint: 'e.g. Mumbai'),
            ),
            FutureBuilder<bool>(
              future: Native.calPerms(),
              builder: (_, snap) => ListTile(
                leading: Icon(Icons.calendar_month_rounded, color: c.muted),
                title: Text('Calendar access', style: TextStyle(color: c.text)),
                subtitle: Text(snap.data == true ? 'Allowed' : 'Not allowed: tap to allow',
                    style: TextStyle(color: snap.data == true ? VC.green : VC.yellow)),
                onTap: () async {
                  await Native.requestCalendar();
                  prefs.refresh();
                },
              ),
            ),
          ]),
          ],
          if (show.contains('ON-PHONE AI')) ...[
          _section(c, 'ON-PHONE AI'),
          _group(c, [
            FutureBuilder<String>(
              future: Native.nanoStatus(),
              builder: (context, snap) {
                final st = snap.data ?? '…';
                final label = {
                  'available': 'Ready: works offline, nothing leaves your phone',
                  'downloadable': 'Not downloaded yet: tap to download (Wi-Fi recommended)',
                  'downloading': 'Downloading… you can keep using Vibe',
                  'unavailable': 'Not available on this phone right now',
                }[st] ?? 'Checking…';
                return ListTile(
                  leading: Icon(Icons.phone_android_rounded, color: c.muted),
                  title: Text('Gemini Nano', style: TextStyle(color: c.text)),
                  subtitle: Text(label,
                      style: TextStyle(color: st == 'available' ? VC.green : st == 'unavailable' ? c.faint : VC.yellow)),
                  onTap: st == 'downloadable'
                      ? () async {
                          final m = ScaffoldMessenger.of(context);
                          m.showSnackBar(const SnackBar(content: Text('Downloading the on-phone AI…')));
                          final ok = await Native.nanoDownload();
                          m.showSnackBar(SnackBar(
                              content: Text(ok ? 'On-phone AI is ready' : 'Download didn\'t finish. Try again on Wi-Fi')));
                          prefs.refresh();
                        }
                      : null,
                );
              },
            ),
          ]),
          ],
          if (show.contains('VIBE AI (GEMINI)')) ...[
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
            ListTile(
              leading: Icon(Icons.alt_route_rounded, color: c.muted),
              title: Text('Backup AI (OpenRouter)', style: TextStyle(color: c.text)),
              subtitle: Text(
                  prefs.routerKey.isEmpty
                      ? 'Optional: answers when Gemini is busy'
                      : 'Set (…${prefs.routerKey.substring(prefs.routerKey.length < 4 ? 0 : prefs.routerKey.length - 4)})${prefs.routerModels.isEmpty ? '' : ' · ${prefs.routerModels.length} free models'}',
                  style: TextStyle(color: c.faint)),
              trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
              onTap: () => _editText(context, 'OpenRouter API key', prefs.routerKey, prefs.setRouterKey,
                  hint: 'Paste your key', secret: true),
            ),
            ListTile(
              leading: Icon(Icons.open_in_new_rounded, color: c.muted),
              title: Text('Get a free OpenRouter key', style: TextStyle(color: c.text)),
              subtitle: Text('openrouter.ai → Keys', style: TextStyle(color: c.faint)),
              onTap: () => Native.openUrl('https://openrouter.ai/keys'),
            ),
          ]),
          ],
          if (show.contains('PRIVACY')) ...[
          _section(c, 'PRIVACY'),
          _group(c, [
            ListTile(
              leading: const Icon(Icons.shield_rounded, color: VC.green),
              title: Text('Private details stay on your phone', style: TextStyle(color: c.text)),
              subtitle: Text(
                  'OTPs, bank and payment alerts, passwords and notifications from banking, payment and '
                  'authenticator apps are never sent to Gemini or OpenRouter. "What did I miss?" is summarised '
                  'on the phone when the on-phone AI is ready.\n\n'
                  'Free cloud AI tiers may use what you send to improve their services, so avoid sending '
                  'anything you wouldn\'t want a stranger to read. Keys are stored encrypted, and Vibe\'s '
                  'data is excluded from cloud backups.',
                  style: TextStyle(color: c.faint, height: 1.35)),
              isThreeLine: true,
            ),
          ]),
          ],
          if (show.contains('LOOK')) ...[
          _section(c, 'ACCENT COLOUR'),
          _group(c, [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                for (final a in VC.accents)
                  GestureDetector(
                    onTap: () { prefs.tap(); prefs.setAccent(a.toARGB32()); },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: a,
                        shape: BoxShape.circle,
                        border: Border.all(color: prefs.accent == a.toARGB32() ? c.text : Colors.transparent, width: 3),
                      ),
                      child: prefs.accent == a.toARGB32() ? const Icon(Icons.check_rounded, color: Colors.white) : null,
                    ),
                  ),
              ]),
            ),
          ]),
          _section(c, 'WALLPAPER'),
          _group(c, [
            ListTile(
              leading: prefs.wallpaper.isNotEmpty && File(prefs.wallpaper).existsSync()
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(File(prefs.wallpaper), width: 36, height: 36, fit: BoxFit.cover, cacheWidth: 120))
                  : Icon(Icons.wallpaper_rounded, color: c.muted),
              title: Text(prefs.wallpaper.isEmpty ? 'Choose a wallpaper' : 'Change wallpaper', style: TextStyle(color: c.text)),
              subtitle: Text('Shown behind the chat', style: TextStyle(color: c.faint)),
              onTap: () async {
                final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, maxHeight: 2400, imageQuality: 88);
                if (x == null) return;
                final dir = await Native.filesDir();
                final path = '$dir/wallpaper_${DateTime.now().millisecondsSinceEpoch}.jpg';
                await File(x.path).copy(path);
                prefs.setWallpaper(path);
              },
            ),
            if (prefs.wallpaper.isNotEmpty) ...[
              _radio(c, 'Dim: light', prefs.wallDim == 0, () => prefs.setWallDim(0)),
              _radio(c, 'Dim: medium', prefs.wallDim == 1, () => prefs.setWallDim(1)),
              _radio(c, 'Dim: strong', prefs.wallDim == 2, () => prefs.setWallDim(2)),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: VC.red),
                title: const Text('Remove wallpaper', style: TextStyle(color: VC.red)),
                onTap: () => prefs.setWallpaper(''),
              ),
            ],
          ]),
          _section(c, 'ICONS'),
          _group(c, [
            FutureBuilder<List<Map>>(
              future: Native.iconPacks(),
              builder: (context, snap) {
                final packs = snap.data ?? [];
                String name = 'System icons';
                for (final p in packs) {
                  if (p['package'] == prefs.iconPack) name = p['label'].toString();
                }
                return ListTile(
                  leading: Icon(Icons.style_rounded, color: c.muted),
                  title: Text('Icon pack', style: TextStyle(color: c.text)),
                  subtitle: Text(packs.isEmpty ? 'No icon packs installed' : name, style: TextStyle(color: c.faint)),
                  trailing: Icon(Icons.chevron_right_rounded, color: c.faint),
                  onTap: packs.isEmpty
                      ? () => Native.openUrl('https://play.google.com/store/search?q=icon%20pack&c=apps')
                      : () => showModalBottomSheet(
                            context: context,
                            showDragHandle: true,
                            builder: (ctx) => SafeArea(
                              child: ListView(shrinkWrap: true, children: [
                                _radio(c, 'System icons', prefs.iconPack.isEmpty, () {
                                  prefs.setIconPack('');
                                  Navigator.pop(ctx);
                                }),
                                for (final p in packs)
                                  _radio(c, p['label'].toString(), prefs.iconPack == p['package'], () {
                                    prefs.setIconPack(p['package'].toString());
                                    Navigator.pop(ctx);
                                  }),
                              ]),
                            ),
                          ),
                );
              },
            ),
            SwitchListTile(
              title: Text('Round icons', style: TextStyle(color: c.text)),
              subtitle: Text('Off keeps each icon\'s own shape (best with icon packs)', style: TextStyle(color: c.faint)),
              value: prefs.roundIcons,
              onChanged: prefs.setRoundIcons,
            ),
          ]),
          _section(c, 'MESSAGE SPACING'),
          _group(c, [
            _radio(c, 'Comfy', !prefs.compact, () => prefs.setCompact(false)),
            _radio(c, 'Compact', prefs.compact, () => prefs.setCompact(true)),
          ]),
          ],
          if (show.contains('SEARCH')) ...[
          _section(c, 'SEARCH ON THIS PHONE'),
          _group(c, [
            FutureBuilder<Map>(
              future: Native.searchPerms(),
              builder: (context, snap) {
                final m = snap.data ?? {};
                return Column(children: [
                  ListTile(
                    leading: Icon(Icons.sms_rounded, color: c.muted),
                    title: Text('SMS search', style: TextStyle(color: c.text)),
                    subtitle: Text(m['sms'] == true ? 'Allowed' : 'Not allowed: tap to allow',
                        style: TextStyle(color: m['sms'] == true ? VC.green : VC.yellow)),
                    onTap: () async { await Native.requestSms(); prefs.refresh(); },
                  ),
                  ListTile(
                    leading: Icon(Icons.folder_rounded, color: c.muted),
                    title: Text('Documents & PDFs', style: TextStyle(color: c.text)),
                    subtitle: Text(m['files'] == true ? 'Allowed' : 'Needs "All files access": tap to allow',
                        style: TextStyle(color: m['files'] == true ? VC.green : VC.yellow)),
                    onTap: () async { await Native.requestFiles(); prefs.refresh(); },
                  ),
                ]);
              },
            ),
          ]),
          _section(c, 'GMAIL (OPTIONAL)'),
          _group(c, [
            ListTile(
              leading: Icon(Icons.alternate_email_rounded, color: c.muted),
              title: Text('Gmail address', style: TextStyle(color: c.text)),
              subtitle: Text(prefs.gmailUser.isEmpty ? 'Not set' : prefs.gmailUser, style: TextStyle(color: c.faint)),
              onTap: () => _editText(context, 'Gmail address', prefs.gmailUser,
                  (v) => prefs.setGmail(v, prefs.gmailPass), hint: 'you@gmail.com'),
            ),
            ListTile(
              leading: Icon(Icons.password_rounded, color: c.muted),
              title: Text('App password', style: TextStyle(color: c.text)),
              subtitle: Text(prefs.gmailPass.isEmpty ? 'Not set' : 'Set · stored encrypted on this phone',
                  style: TextStyle(color: c.faint)),
              onTap: () => _editText(context, 'Gmail app password', prefs.gmailPass,
                  (v) => prefs.setGmail(prefs.gmailUser, v), hint: '16 letters from Google', secret: true),
            ),
            ListTile(
              leading: Icon(Icons.open_in_new_rounded, color: c.muted),
              title: Text('Create an app password', style: TextStyle(color: c.text)),
              subtitle: Text('Google account → Security → App passwords (needs 2-step verification)',
                  style: TextStyle(color: c.faint)),
              onTap: () => Native.openUrl('https://myaccount.google.com/apppasswords'),
            ),
            if (Mail.ready)
              ListTile(
                leading: Icon(Icons.wifi_tethering_rounded, color: c.muted),
                title: Text('Test connection', style: TextStyle(color: c.text)),
                onTap: () async {
                  final m = ScaffoldMessenger.of(context);
                  m.showSnackBar(const SnackBar(content: Text('Connecting to Gmail…')));
                  try {
                    final hits = await Mail.search('in:inbox', max: 3);
                    m.showSnackBar(SnackBar(content: Text('Works! Latest: ${hits.isEmpty ? 'inbox empty' : hits.first.subject}')));
                  } catch (e) {
                    m.showSnackBar(SnackBar(content: Text('$e')));
                  }
                },
              ),
            if (Mail.ready)
              ListTile(
                leading: const Icon(Icons.logout_rounded, color: VC.red),
                title: const Text('Remove Gmail', style: TextStyle(color: VC.red)),
                onTap: () => prefs.setGmail('', ''),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                  'Without this, search still finds your mail notifications and offers "Search Gmail", which opens Gmail. '
                  'With it, Vibe searches your whole mailbox directly. The app password can read your mail, so it\'s '
                  'encrypted on this phone, only ever sent to Gmail, and you can revoke it any time in your Google account.',
                  style: TextStyle(color: c.faint, fontSize: 13, height: 1.35)),
            ),
          ]),
          ],
          if (show.contains('BACKUP')) ...[
          _section(c, 'BACKUP & RESTORE'),
          _group(c, [
            ListTile(
              leading: Icon(Icons.save_alt_rounded, color: c.muted),
              title: Text('Back up now', style: TextStyle(color: c.text)),
              subtitle: Text('Chat, memory, reminders & settings → a file you choose', style: TextStyle(color: c.faint)),
              onTap: () async {
                final m = ScaffoldMessenger.of(context);
                final d = DateTime.now();
                final name = 'vibe-backup-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.json';
                final ok = await Native.saveDoc(name, await Backup.export());
                m.showSnackBar(SnackBar(content: Text(ok ? 'Backup saved' : 'Backup not saved')));
              },
            ),
            ListTile(
              leading: Icon(Icons.restore_rounded, color: c.muted),
              title: Text('Restore from a file', style: TextStyle(color: c.text)),
              subtitle: Text('Replaces chat, memory & settings on this phone', style: TextStyle(color: c.faint)),
              onTap: () async {
                final m = ScaffoldMessenger.of(context);
                final text = await Native.openDoc();
                if (text == null || !context.mounted) return;
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Restore this backup?', style: TextStyle(color: c.text)),
                    content: Text('Your current chat, memory and settings will be replaced.', style: TextStyle(color: c.muted)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
                    ],
                  ),
                );
                if (ok != true) return;
                try {
                  m.showSnackBar(SnackBar(content: Text(await Backup.restore(text))));
                } catch (e) {
                  m.showSnackBar(SnackBar(content: Text('Couldn\'t restore: $e')));
                }
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                  'API keys and the Gmail app password are never put in backups. Add them again after restoring. '
                  'Pictures you sent in the chat aren\'t included either.',
                  style: TextStyle(color: c.faint, fontSize: 13, height: 1.35)),
            ),
          ]),
          ],
          if (show.contains('FEEL')) ...[
          _section(c, 'FEEL'),
          _group(c, [
            SwitchListTile(
              title: Text('Haptics', style: TextStyle(color: c.text)),
              subtitle: Text('Light vibration on taps', style: TextStyle(color: c.faint)),
              value: prefs.haptics,
              onChanged: prefs.setHaptics,
            ),
          ]),
          ],
          if (show.contains('PHONE')) ...[
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
          ],
          if (show.contains('ABOUT')) ...[
          _section(c, 'ABOUT'),
          _group(c, [
            ListTile(
              leading: Icon(Icons.info_outline_rounded, color: c.muted),
              title: Text('Vibe Launcher', style: TextStyle(color: c.text)),
              subtitle: Text('Version 0.16.0', style: TextStyle(color: c.faint)),
            ),
          ]),
          ],
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
              return Center(child: CircularProgressIndicator(color: VC.blurple));
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

/// Everything Vibe remembers, with delete and add.
class _MemoryPage extends StatelessWidget {
  const _MemoryPage();

  Future<void> _add(BuildContext context) async {
    final c = VC.of(context);
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remember…', style: TextStyle(color: c.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(color: c.text),
          decoration: const InputDecoration(hintText: 'e.g. My brother is Ravi'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (v != null && v.trim().isNotEmpty) memory.add(v);
  }

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    return ListenableBuilder(
      listenable: memory,
      builder: (context, _) => Scaffold(
        backgroundColor: c.chat,
        appBar: AppBar(
          backgroundColor: c.chat,
          title: const Text('What Vibe remembers'),
          actions: [
            if (memory.facts.isNotEmpty)
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('Forget everything?', style: TextStyle(color: c.text)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: VC.red),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Forget all'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) memory.clear();
                },
                child: const Text('Clear', style: TextStyle(color: VC.red)),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: VC.blurple,
          foregroundColor: Colors.white,
          onPressed: () => _add(context),
          child: const Icon(Icons.add_rounded),
        ),
        body: memory.facts.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('Nothing yet.\nTell Vibe "remember my brother is Ravi" or tap +.',
                      textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 15)),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: memory.facts.length,
                itemBuilder: (_, i) {
                  final idx = memory.facts.length - 1 - i; // newest first
                  return ListTile(
                    leading: Icon(Icons.bookmark_rounded, color: VC.blurple),
                    title: Text(memory.facts[idx], style: TextStyle(color: c.text)),
                    trailing: IconButton(
                      icon: Icon(Icons.close_rounded, color: c.faint),
                      onPressed: () => memory.removeAt(idx),
                    ),
                  );
                },
              ),
      ),
    );
  }
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


class _SubPage extends StatelessWidget {
  final String title;
  final Set<String> show;
  const _SubPage({required this.title, required this.show});
  @override
  Widget build(BuildContext context) => const SettingsPage()._page(context, title, show);
}

/// Settings card, same look as vibe-flutter's settings page.
class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title, subtitle;
  final String? badge;
  final Color? badgeColor;
  final VoidCallback onTap;
  const _SettingsCard(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap,
      this.iconColor,
      this.badge,
      this.badgeColor});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final b = badgeColor ?? VC.blurple;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Pressable(
        scale: 0.98,
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: c.divider)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              prefs.tap();
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: c.dark ? const Color(0xFF323136) : const Color(0xFFE3E5E8)),
                  child: Icon(icon, color: iconColor ?? c.text, size: 26),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.muted)),
                  ]),
                ),
                if (badge != null)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: b.withAlpha(40),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: b.withAlpha(140)),
                    ),
                    child: Text(badge!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: b)),
                  ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, color: c.muted),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
