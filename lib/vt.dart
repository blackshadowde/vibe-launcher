import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'launcher.dart';

/// A VirusTotal verdict for a file, app or link.
class VtReport {
  final String kind; // file / url
  final String verdict; // clean / suspicious / flagged / unknown / error
  final int malicious, suspicious, total;
  final String label; // e.g. "trojan.android/agent"
  final String name;
  final String link; // full report on virustotal.com
  final String sha256;
  final String error;
  const VtReport(this.kind, this.verdict,
      {this.malicious = 0, this.suspicious = 0, this.total = 0, this.label = '', this.name = '', this.link = '', this.sha256 = '', this.error = ''});

  Map toCard({String title = '', Map? source}) => {
        'type': 'vt',
        'kind': kind,
        'verdict': verdict,
        'mal': malicious,
        'sus': suspicious,
        'total': total,
        'label': label,
        'name': name,
        'title': title,
        'link': link,
        'sha256': sha256,
        'error': error,
        if (source != null) 'source': source,
      };
}

/// VirusTotal (free public API: 4 requests a minute, 500 a day; personal use).
/// Files are checked by fingerprint first; they are uploaded only when you tap Upload.
class VirusTotal {
  static const _base = 'https://www.virustotal.com/api/v3';
  static bool get ready => prefs.vtKey.trim().length >= 32;

  // Keep to the free limit: at most one request every 15 seconds
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<void> _slot() async {
    final wait = _last.add(const Duration(seconds: 15)).difference(DateTime.now());
    if (!wait.isNegative) await Future.delayed(wait);
    _last = DateTime.now();
  }

  static Future<(int, Map)> _req(String method, String url, {Map<String, String>? form, File? file, String? fileName}) async {
    await _slot();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final r = await client.openUrl(method, Uri.parse(url));
      r.headers.set('x-apikey', prefs.vtKey.trim());
      r.headers.set('accept', 'application/json');
      if (form != null) {
        r.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
        r.write(form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'));
      } else if (file != null) {
        final boundary = 'vibe${Random().nextInt(1 << 32)}';
        r.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
        final head = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="${fileName ?? 'file'}"\r\n'
            'Content-Type: application/octet-stream\r\n\r\n');
        final tail = utf8.encode('\r\n--$boundary--\r\n');
        r.contentLength = head.length + await file.length() + tail.length;
        r.add(head);
        await r.addStream(file.openRead());
        r.add(tail);
      }
      final res = await r.close().timeout(const Duration(minutes: 10));
      final raw = await res.transform(utf8.decoder).join();
      Map j = {};
      try {
        j = jsonDecode(raw) as Map;
      } catch (_) {}
      return (res.statusCode, j);
    } on SocketException {
      return (-1, {'error': {'message': 'No internet'}});
    } catch (e) {
      return (-1, {'error': {'message': '$e'}});
    } finally {
      client.close();
    }
  }

  static String _err(int code, Map j) {
    if (code == 401) return 'Your VirusTotal key isn\'t working. Check it in Vibe settings → Security.';
    if (code == 429) return 'VirusTotal\'s free limit is used up for now (500 a day). Try again later.';
    return '${(j['error'] as Map?)?['message'] ?? 'VirusTotal error $code'}';
  }

  static VtReport _fromFile(Map j) {
    final a = (j['data'] as Map?)?['attributes'] as Map? ?? const {};
    final st = a['last_analysis_stats'] as Map? ?? const {};
    int n(String k) => (st[k] as num?)?.toInt() ?? 0;
    final mal = n('malicious'), sus = n('suspicious');
    final total = mal + sus + n('undetected') + n('harmless');
    final hash = '${a['sha256'] ?? (j['data'] as Map?)?['id'] ?? ''}';
    return VtReport('file', mal > 2 ? 'flagged' : (mal > 0 || sus > 0) ? 'suspicious' : 'clean',
        malicious: mal,
        suspicious: sus,
        total: total,
        label: '${(a['popular_threat_classification'] as Map?)?['suggested_threat_label'] ?? ''}',
        name: '${a['meaningful_name'] ?? ''}',
        link: 'https://www.virustotal.com/gui/file/$hash',
        sha256: hash);
  }

  /// Looks a file up by its SHA-256 fingerprint. Nothing is uploaded.
  static Future<VtReport> lookup(String sha256) async {
    final (code, j) = await _req('GET', '$_base/files/$sha256');
    if (code == 200) return _fromFile(j);
    if (code == 404) return VtReport('file', 'unknown', sha256: sha256, link: 'https://www.virustotal.com/gui/file/$sha256');
    return VtReport('file', 'error', error: _err(code, j), sha256: sha256);
  }

  /// Uploads a file you approved, waits for the scan, and returns the report.
  static Future<VtReport> upload(String path, String name, {void Function(String)? status}) async {
    final f = File(path);
    final size = await f.length();
    var url = '$_base/files';
    if (size > 32 * 1024 * 1024) {
      if (size > 650 * 1024 * 1024) return const VtReport('file', 'error', error: 'Too big to upload (VirusTotal takes up to 650 MB).');
      final (c, j) = await _req('GET', '$_base/files/upload_url');
      if (c != 200) return VtReport('file', 'error', error: _err(c, j));
      url = '${j['data']}';
    }
    status?.call('Uploading…');
    final (code, j) = await _req('POST', url, file: f, fileName: name);
    try {
      f.deleteSync();
    } catch (_) {}
    if (code != 200) return VtReport('file', 'error', error: _err(code, j));
    final id = '${(j['data'] as Map?)?['id'] ?? ''}';
    return _waitAnalysis(id, status: status);
  }

  static Future<VtReport> _waitAnalysis(String id, {void Function(String)? status}) async {
    for (var i = 0; i < 20; i++) {
      status?.call('Scanning with ~70 antivirus engines…');
      final (code, j) = await _req('GET', '$_base/analyses/$id');
      if (code != 200) return VtReport('file', 'error', error: _err(code, j));
      final a = (j['data'] as Map?)?['attributes'] as Map? ?? const {};
      if (a['status'] == 'completed') {
        final st = a['stats'] as Map? ?? const {};
        int n(String k) => (st[k] as num?)?.toInt() ?? 0;
        final mal = n('malicious'), sus = n('suspicious');
        final meta = j['meta'] as Map? ?? const {};
        final hash = '${(meta['file_info'] as Map?)?['sha256'] ?? ''}';
        final urlInfo = meta['url_info'] as Map?;
        final isUrl = urlInfo != null;
        return VtReport(isUrl ? 'url' : 'file', mal > 2 ? 'flagged' : (mal > 0 || sus > 0) ? 'suspicious' : 'clean',
            malicious: mal,
            suspicious: sus,
            total: mal + sus + n('undetected') + n('harmless'),
            link: isUrl ? 'https://www.virustotal.com/gui/url/${urlInfo['id']}' : 'https://www.virustotal.com/gui/file/$hash',
            sha256: hash,
            name: isUrl ? '${urlInfo['url'] ?? ''}' : '');
      }
    }
    return const VtReport('file', 'error', error: 'VirusTotal is still scanning. Check again in a few minutes.');
  }

  /// A website's verdict: the existing report if VirusTotal knows the link, otherwise a fresh scan.
  static Future<VtReport> checkUrl(String url) async {
    final id = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    final (code, j) = await _req('GET', '$_base/urls/$id');
    if (code == 200) {
      final a = (j['data'] as Map?)?['attributes'] as Map? ?? const {};
      final st = a['last_analysis_stats'] as Map? ?? const {};
      int n(String k) => (st[k] as num?)?.toInt() ?? 0;
      final mal = n('malicious'), sus = n('suspicious');
      return VtReport('url', mal > 1 ? 'flagged' : (mal > 0 || sus > 0) ? 'suspicious' : 'clean',
          malicious: mal,
          suspicious: sus,
          total: mal + sus + n('undetected') + n('harmless'),
          name: url,
          link: 'https://www.virustotal.com/gui/url/$id');
    }
    if (code != 404) return VtReport('url', 'error', error: _err(code, j), name: url);
    final (c2, j2) = await _req('POST', '$_base/urls', form: {'url': url});
    if (c2 != 200) return VtReport('url', 'error', error: _err(c2, j2), name: url);
    return _waitAnalysis('${(j2['data'] as Map?)?['id'] ?? ''}');
  }
}
