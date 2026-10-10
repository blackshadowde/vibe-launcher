import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'launcher.dart';
import 'theme.dart';

/// Vibe's own music player (songs stored on the phone), driven by the Android side (Media3).
class VibePlayer extends ChangeNotifier {
  VibePlayer._();
  static final VibePlayer i = VibePlayer._();

  bool playing = false, ready = false;
  String title = '', artist = '', uri = '';
  String? art;
  int pos = 0, dur = 0, index = 0, count = 0;
  int _at = 0; // when [pos] was measured
  Timer? _tick;

  /// True while Vibe's player has something loaded (pause / next go here, not to other apps).
  bool get active => ready && count > 0;

  /// Position right now, counted forward while playing.
  int get position {
    if (!playing) return pos;
    final p = pos + (DateTime.now().millisecondsSinceEpoch - _at);
    return dur > 0 ? p.clamp(0, dur) : p;
  }

  void onEvent(Map m) {
    playing = m['playing'] == true;
    ready = m['ready'] == true;
    title = '${m['title'] ?? ''}';
    artist = '${m['artist'] ?? ''}';
    art = m['art'] as String?;
    uri = '${m['uri'] ?? ''}';
    pos = (m['pos'] as num?)?.toInt() ?? 0;
    dur = (m['dur'] as num?)?.toInt() ?? 0;
    index = (m['index'] as num?)?.toInt() ?? 0;
    count = (m['count'] as num?)?.toInt() ?? 0;
    _at = DateTime.now().millisecondsSinceEpoch;
    _tick?.cancel();
    if (playing) _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => notifyListeners());
    notifyListeners();
  }

  Future<void> play(List<Map> songs, {int index = 0}) => Native.playSongs(songs, index);
  Future<void> cmd(String action, {int ms = 0}) => Native.playerCmd(action, ms: ms);

  static final _art = <String, Future<Uint8List?>>{};
  static Future<Uint8List?> artFor(String songUri) => _art.putIfAbsent(songUri, () => Native.songArt(songUri));
}

String _mmss(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Album art (or a music note) for a song on the phone.
class SongArt extends StatelessWidget {
  final String uri;
  final double size;
  const SongArt({super.key, required this.uri, this.size = 56});
  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: VC.blurple, borderRadius: BorderRadius.circular(10)),
      child: Icon(Icons.music_note_rounded, color: Colors.white, size: size * 0.5),
    );
    if (uri.isEmpty) return fallback;
    return FutureBuilder<Uint8List?>(
      future: VibePlayer.artFor(uri),
      builder: (_, s) => s.data == null
          ? (s.connectionState == ConnectionState.done ? fallback : Container(width: size, height: size, decoration: BoxDecoration(color: c.input, borderRadius: BorderRadius.circular(10))))
          : ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(s.data!, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
            ),
    );
  }
}

/// The player card in the timeline. Live while it's the song playing; otherwise tap ▶ to play it again.
class PlayerCard extends StatelessWidget {
  final Map card; // {'type':'player', 'songs':[…], 'index':0}
  const PlayerCard({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final songs = List<Map>.from(card['songs'] as List? ?? const []);
    final start = (card['index'] as num?)?.toInt() ?? 0;
    return ListenableBuilder(
      listenable: VibePlayer.i,
      builder: (context, _) {
        final p = VibePlayer.i;
        final mine = p.active && songs.any((s) => s['uri'] == p.uri);
        final cur = mine ? songs.firstWhere((s) => s['uri'] == p.uri) : (songs.isEmpty ? const {} : songs[start.clamp(0, songs.length - 1)]);
        final title = mine ? p.title : '${cur['title'] ?? ''}';
        final artist = mine ? p.artist : '${cur['artist'] ?? ''}';
        final dur = mine ? p.dur : (cur['duration'] as num?)?.toInt() ?? 0;
        final pos = mine ? p.position : 0;
        Widget btn(IconData i, VoidCallback f, {bool big = false}) => InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                prefs.tap();
                f();
              },
              child: Container(
                width: big ? 46 : 38,
                height: big ? 46 : 38,
                decoration: big ? BoxDecoration(color: VC.blurple, shape: BoxShape.circle) : null,
                child: Icon(i, color: big ? Colors.white : c.text, size: big ? 28 : 24),
              ),
            );
        return Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxWidth: 380),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.divider)),
          child: Column(children: [
            Row(children: [
              SongArt(uri: '${cur['uri'] ?? ''}', size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 15)),
                  if (artist.isNotEmpty)
                    Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.muted, fontSize: 13)),
                  if (songs.length > 1)
                    Text(mine ? '${p.index + 1} of ${p.count}' : '${songs.length} songs',
                        style: TextStyle(color: c.faint, fontSize: 11)),
                ]),
              ),
              if (mine) btn(Icons.skip_previous_rounded, () => p.cmd('previous')),
              btn(mine && p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  () => mine ? p.cmd('toggle') : p.play(songs, index: start),
                  big: true),
              if (mine) btn(Icons.skip_next_rounded, () => p.cmd('next')),
            ]),
            if (mine && dur > 0)
              Row(children: [
                Text(_mmss(pos), style: TextStyle(color: c.faint, fontSize: 11)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: pos.clamp(0, dur).toDouble(),
                      max: dur.toDouble(),
                      activeColor: VC.blurple,
                      inactiveColor: c.input,
                      onChanged: (v) => p.cmd('seek', ms: v.toInt()),
                    ),
                  ),
                ),
                Text(_mmss(dur), style: TextStyle(color: c.faint, fontSize: 11)),
              ]),
          ]),
        );
      },
    );
  }
}
