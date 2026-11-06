import 'dart:convert';
import 'dart:io';

/// Small HTTP helper with a cookie jar, built on dart:io so that multiple
/// Set-Cookie headers are handled correctly (package:http folds them).
class BrowserSession {
  final HttpClient _client = HttpClient()
    ..userAgent = null
    ..connectionTimeout = const Duration(seconds: 25);
  final Map<String, Map<String, String>> _jar = {}; // host -> name -> value

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  String _cookieHeader(Uri uri) {
    final host = _baseHost(uri.host);
    final m = _jar[host];
    if (m == null || m.isEmpty) return '';
    return m.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _store(Uri uri, List<Cookie> cookies) {
    final host = _baseHost(uri.host);
    final m = _jar.putIfAbsent(host, () => {});
    for (final c in cookies) {
      m[c.name] = c.value;
    }
  }

  static String _baseHost(String host) {
    final parts = host.split('.');
    if (parts.length <= 2) return host;
    return parts.sublist(parts.length - 2).join('.');
  }

  Future<HttpResult> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxRedirects = 5,
  }) async {
    var current = uri;
    for (var i = 0; i <= maxRedirects; i++) {
      final req = await _client.getUrl(current);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      req.headers.set(HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
      headers.forEach(req.headers.set);
      final ck = _cookieHeader(current);
      if (ck.isNotEmpty) req.headers.set(HttpHeaders.cookieHeader, ck);
      final res = await req.close();
      _store(current, res.cookies);
      if (res.isRedirect && res.headers.value('location') != null) {
        await res.drain<void>();
        current = current.resolve(res.headers.value('location')!);
        continue;
      }
      final body = await res.transform(utf8.decoder).join();
      return HttpResult(res.statusCode, body, current);
    }
    throw HttpException('Too many redirects for $uri');
  }

  Future<HttpResult> postJson(Uri uri, Map<String, dynamic> body,
      {Map<String, String> headers = const {}}) async {
    final req = await _client.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.userAgentHeader, 'vinted-scout/1.0');
    headers.forEach(req.headers.set);
    req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return HttpResult(res.statusCode, text, uri);
  }

  void close() => _client.close(force: true);
}

class HttpResult {
  final int status;
  final String body;
  final Uri finalUri;
  HttpResult(this.status, this.body, this.finalUri);
  bool get ok => status >= 200 && status < 300;
}

/// Strip an HTML document down to readable text (scripts/styles removed,
/// tags dropped, whitespace collapsed). Good enough for an LLM to read.
String htmlToText(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<noscript[\s\S]*?</noscript>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'</(div|li|p|h\d|tr|span|a)>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = s
      .replaceAll('&amp;', '&')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#x27;', "'");
  s = s.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
  s = s.replaceAll(RegExp(r'\n\s*\n+'), '\n');
  return s.trim();
}
