import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'launcher.dart';

/// Makes pictures with Cloudflare Workers AI (FLUX), using your own free Cloudflare account.
class ImageGen {
  static bool get ready =>
      RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(prefs.cfAccount.trim()) && prefs.cfToken.isNotEmpty;

  /// "draw a cat", "create an image of …", "make a wallpaper of …" → the prompt, or null.
  static ({String prompt, bool wallpaper})? parse(String input) {
    final t = input.trim();
    final draw = RegExp(r'^(?:please\s+)?(?:draw|paint|sketch)\s+(?:me\s+)?(.+)$', caseSensitive: false).firstMatch(t);
    if (draw != null) return (prompt: draw.group(1)!.trim(), wallpaper: false);
    final make = RegExp(
            r'^(?:please\s+)?(?:create|generate|make|design|imagine)\s+(?:me\s+)?(?:an?\s+|the\s+)?'
            r'(image|picture|pic|photo|wallpaper|drawing|art|artwork|logo|poster|sticker|illustration|painting)s?\s*'
            r'(?:of|showing|with|for|about)?\s*(.+)$',
            caseSensitive: false)
        .firstMatch(t);
    if (make != null) {
      return (prompt: make.group(2)!.trim(), wallpaper: make.group(1)!.toLowerCase() == 'wallpaper');
    }
    return null;
  }

  /// Returns the saved picture's path, or throws a readable message.
  static Future<String> draw(String prompt, {bool wallpaper = false}) async {
    final full = wallpaper ? '$prompt, phone wallpaper, tall vertical composition, high detail' : prompt;
    final uri = Uri.parse('https://api.cloudflare.com/client/v4/accounts/${prefs.cfAccount}'
        '/ai/run/@cf/black-forest-labs/flux-1-schnell');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('Authorization', 'Bearer ${prefs.cfToken}');
      req.add(utf8.encode(jsonEncode({'prompt': full.length > 2000 ? full.substring(0, 2000) : full, 'steps': 6})));
      final res = await req.close().timeout(const Duration(seconds: 90));
      final raw = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw ImageError('Cloudflare didn\'t accept the account ID or token. Check them in Vibe settings → Vibe AI.');
      }
      if (res.statusCode == 429) throw ImageError('Today\'s free picture limit on Cloudflare is used up. Try tomorrow.');
      Map j = {};
      try {
        j = jsonDecode(raw) as Map;
      } catch (_) {}
      final b64 = (j['result'] is Map ? j['result']['image'] : null) ?? j['image'];
      if (res.statusCode != 200 || b64 is! String) {
        final err = (j['errors'] is List && (j['errors'] as List).isNotEmpty) ? (j['errors'] as List).first['message'] : null;
        throw ImageError(err == null ? 'Couldn\'t make that picture right now.' : 'Cloudflare: $err');
      }
      final dir = await Native.filesDir();
      final path = '$dir/drawn_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(base64Decode(b64));
      return path;
    } on SocketException {
      throw ImageError('I need internet to draw. You seem to be offline.');
    } on TimeoutException {
      throw ImageError('Cloudflare took too long. Try again.');
    } finally {
      client.close();
    }
  }
}

class ImageError implements Exception {
  final String message;
  ImageError(this.message);
  @override
  String toString() => message;
}
