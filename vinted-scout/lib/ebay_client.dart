import 'net.dart';
import 'web_fetcher.dart';

class EbayException implements Exception {
  final String message;
  EbayException(this.message);
  @override
  String toString() => message;
}

/// Fetches eBay's real Sold Items search (never Terapeak) and returns the
/// page as plain text for the comp reader, plus the URL for the user.
///
/// eBay bot-checks plain HTTP clients, so the page is loaded in a hidden
/// real browser engine first; plain HTTP is only a fallback.
class EbayClient {
  final BrowserSession session;
  final WebFetcher web;
  EbayClient(this.session, {WebFetcher? web}) : web = web ?? WebFetcher();

  static Uri soldSearchUri(String query, {required String compCondition}) {
    final qp = <String, String>{
      '_nkw': query,
      'LH_Sold': '1',
      'LH_Complete': '1',
      '_sop': '13', // ended recently
      '_ipg': '60',
    };
    // 1000 = New, 3000 = Used. Leave unfiltered for "any".
    if (compCondition == 'sealed') qp['LH_ItemCondition'] = '1000';
    if (compCondition == 'used') qp['LH_ItemCondition'] = '3000';
    return Uri.https('www.ebay.com', '/sch/i.html', qp);
  }

  /// A sold listing line like "Sold Oct 29, 2026".
  static final RegExp soldLine = RegExp(r'Sold\s+[A-Z][a-z]{2}\s+\d{1,2},\s+\d{4}');

  Future<String> soldSearchText(String query,
      {required String compCondition, int maxChars = 9000}) async {
    final uri = soldSearchUri(query, compCondition: compCondition);
    String text;
    try {
      text = await web.pageText(uri.toString(), readyWhen: soldLine);
    } on WebFetchException catch (e) {
      throw EbayException('eBay: $e');
    } catch (e) {
      // Embedded browser unavailable on this device: try plain HTTP, but
      // report why the browser failed so the problem is visible.
      try {
        text = await _plainHttp(uri);
      } on EbayException catch (e2) {
        throw EbayException('${e2.message} Embedded browser also failed: $e');
      }
    }
    if (!soldLine.hasMatch(text)) {
      final preview = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      throw EbayException(
          'eBay page loaded but showed no sold listings (${text.length} chars). '
          'Start of page: "${preview.substring(0, preview.length > 220 ? 220 : preview.length)}"');
    }
    return _trim(text, maxChars);
  }

  Future<String> _plainHttp(Uri uri) async {
    var r = await session.get(uri);
    if (r.status == 503 || r.status == 429) {
      await Future<void>.delayed(const Duration(seconds: 10));
      r = await session.get(uri);
    }
    if (!r.ok) {
      throw EbayException('eBay sold search failed (HTTP ${r.status}).');
    }
    final text = htmlToText(r.body);
    if (WebFetcher.isChallenge(text)) {
      throw EbayException(
          'eBay showed a bot-check page instead of results. Wait a few minutes and scan again.');
    }
    return text;
  }

  static String _trim(String input, int maxChars) {
    var text = input.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n+'), '\n');
    // Start at the results count line if found; skips the filter chrome.
    final idx = text.indexOf(RegExp(r'\d[\d,]* results? for '));
    if (idx > 0) text = text.substring(idx);
    final fewer = text.indexOf('Results matching fewer words');
    if (fewer > 2500) text = text.substring(0, fewer);
    if (text.length > maxChars) text = text.substring(0, maxChars);
    return text;
  }
}
