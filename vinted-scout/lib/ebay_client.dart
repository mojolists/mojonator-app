import 'net.dart';

class EbayException implements Exception {
  final String message;
  EbayException(this.message);
  @override
  String toString() => message;
}

/// Fetches eBay's real Sold Items search (never Terapeak) and returns the
/// page as plain text for the comp reader, plus the URL for the user.
class EbayClient {
  final BrowserSession session;
  EbayClient(this.session);

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

  Future<String> soldSearchText(String query,
      {required String compCondition, int maxChars = 9000}) async {
    final uri = soldSearchUri(query, compCondition: compCondition);
    var r = await session.get(uri);
    if (r.status == 503 || r.status == 429) {
      await Future<void>.delayed(const Duration(seconds: 10));
      r = await session.get(uri);
    }
    if (!r.ok) {
      throw EbayException('eBay sold search failed (HTTP ${r.status}).');
    }
    var text = htmlToText(r.body);
    if (text.contains('Pardon Our Interruption') ||
        text.contains('Checking your browser') ||
        text.contains('verify you are a human')) {
      throw EbayException(
          'eBay showed a bot-check page instead of results. Wait a few minutes and scan again.');
    }
    // Trim the header/filters chrome: start at the results count line if found.
    final idx = text.indexOf(RegExp(r'\d[\d,]* results? for '));
    if (idx > 0) text = text.substring(idx);
    // Drop the "Results matching fewer words" tail if it is far down; the
    // reader is told to ignore it anyway, but it saves tokens.
    final fewer = text.indexOf('Results matching fewer words');
    if (fewer > 2500) text = text.substring(0, fewer);
    if (text.length > maxChars) text = text.substring(0, maxChars);
    return text;
  }
}
