import 'models.dart';
import 'net.dart';

class VintedException implements Exception {
  final String message;
  VintedException(this.message);
  @override
  String toString() => message;
}

/// Reads the public Vinted catalog from the server-rendered HTML pages
/// (Vinted's old JSON catalog endpoint returns 404 now). Each listing card
/// carries an overlay link whose title attribute is
/// "Title, Condition: Very good, 2.00 $, 2.80 $" — that is all we need.
class VintedClient {
  static const host = 'https://www.vinted.com';
  final BrowserSession session;

  VintedClient(this.session);

  // Vinted status_ids: 6 = New with tags, 1 = New without tags, 2 = Very good,
  // 3 = Good, 4 = Satisfactory.
  static List<int> statusIds({required bool includeVeryGood}) =>
      includeVeryGood ? const [6, 1, 2] : const [6, 1];

  static Uri catalogUri({
    required String term,
    required int page,
    required bool includeVeryGood,
  }) {
    final qp = <String, List<String>>{
      'search_text': [term],
      'order': ['newest_first'],
      'status_ids[]':
          statusIds(includeVeryGood: includeVeryGood).map((e) => '$e').toList(),
      if (page > 1) 'page': ['$page'],
    };
    return Uri.parse('$host/catalog').replace(queryParameters: qp);
  }

  static final _overlay = RegExp(
      r'<a href="(/items/(\d+)[^"]*?)\?referrer=catalog"[^>]*?title="([^"]*)"');
  static final _thumb = RegExp(
      r'<img src="([^"]+)"[^>]*?data-testid="product-item-id-(\d+)--image--img"');
  static final _titleParts = RegExp(
      r'^(.*),\s*Condition:\s*([^,]+),\s*([\d.,]+)\s*\$,\s*([\d.,]+)\s*\$\s*$');

  /// One page of search results.
  Future<List<VintedListing>> searchPage({
    required String term,
    required String formatLabel,
    required int page,
    required bool includeVeryGood,
  }) async {
    final uri = catalogUri(term: term, page: page, includeVeryGood: includeVeryGood);
    final r = await session.get(uri);
    if (r.status == 403) {
      throw VintedException(
          'Vinted refused the request (HTTP 403, bot check) for "$term" page $page. Wait a few minutes and try again.');
    }
    if (!r.ok) {
      throw VintedException(
          'Vinted catalog page failed (HTTP ${r.status}) for "$term" page $page.');
    }
    final html = r.body;
    final thumbs = <int, String>{};
    for (final m in _thumb.allMatches(html)) {
      final id = int.tryParse(m.group(2)!);
      if (id != null) thumbs[id] = _decode(m.group(1)!);
    }
    final out = <VintedListing>[];
    final seen = <int>{};
    for (final m in _overlay.allMatches(html)) {
      final id = int.tryParse(m.group(2)!);
      if (id == null || !seen.add(id)) continue;
      final path = m.group(1)!;
      final raw = _decode(m.group(3)!);
      final p = _titleParts.firstMatch(raw);
      String title;
      String condition;
      double? price;
      double? incl;
      if (p != null) {
        title = p.group(1)!.trim();
        condition = p.group(2)!.trim();
        price = _money(p.group(3)!);
        incl = _money(p.group(4)!);
      } else {
        // Fallback: take the last two "$" amounts and the Condition word.
        final amounts = RegExp(r'([\d.,]+)\s*\$').allMatches(raw).toList();
        if (amounts.length < 2) continue;
        price = _money(amounts[amounts.length - 2].group(1)!);
        incl = _money(amounts.last.group(1)!);
        final c = RegExp(r'Condition:\s*([^,]+)').firstMatch(raw);
        condition = c?.group(1)?.trim() ?? '';
        final cut = raw.indexOf(', Condition:');
        title = (cut > 0 ? raw.substring(0, cut) : raw).trim();
      }
      if (price == null || incl == null) continue;
      out.add(VintedListing(
        id: id,
        title: title,
        condition: condition,
        price: price,
        inclPrice: incl,
        url: '$host$path',
        photoUrl: thumbs[id],
        format: formatLabel,
        searchTerm: term,
      ));
    }
    if (out.isEmpty && !html.contains('product-item-id-')) {
      if (html.contains('No results') || html.contains('0 results')) return out;
      throw VintedException(
          'Vinted returned a page without listings for "$term" page $page (layout change or bot-check page).');
    }
    return out;
  }

  static final _metaDesc =
      RegExp(r'<meta name="description" content="([^"]*)"');
  static final _feedback = RegExp(r'feedback_count\\*"\s*:\s*(\d+)');
  static final _sellerName = RegExp(r'\\*"name\\*"\s*:\s*\\*"([^"\\]+)');

  /// Item details for a candidate, scraped from the item page.
  Future<VintedItemDetail?> itemDetail(String itemUrl) async {
    final r = await session.get(Uri.parse(itemUrl));
    if (!r.ok) return null;
    final html = r.body;
    final desc = _decode(_metaDesc.firstMatch(html)?.group(1) ?? '');

    // Seller block: the seller_badges_info JSON holds feedback_count + name.
    var login = '';
    var fb = 0;
    final badgeIdx = html.indexOf('seller_badges_info');
    final slice = badgeIdx >= 0
        ? html.substring(badgeIdx, (badgeIdx + 4000).clamp(0, html.length))
        : html;
    final f = _feedback.firstMatch(slice) ?? _feedback.firstMatch(html);
    if (f != null) fb = int.tryParse(f.group(1)!) ?? 0;
    final n = _sellerName.firstMatch(slice);
    if (n != null) login = n.group(1)!;

    // Shipping banner: "Free shipping" or "Shipping from $X.XX".
    bool? free;
    String? note;
    final b = html.indexOf('data-testid="item-shipping-banner"');
    if (b >= 0) {
      final text = htmlToText(html.substring(b, (b + 3000).clamp(0, html.length)));
      if (text.contains('Free shipping')) {
        free = true;
      } else {
        final m = RegExp(r'from \$([\d.]+)').firstMatch(text);
        if (m != null) {
          note = 'Shipping from \$${m.group(1)}';
          free = m.group(1) == '0.00' ? null : false;
        }
      }
    }
    return VintedItemDetail(
      description: desc,
      sellerLogin: login,
      sellerFeedbackCount: fb,
      freeShipping: free,
      shippingNote: note,
    );
  }

  static double? _money(String s) =>
      double.tryParse(s.replaceAll(',', '').trim());

  static String _decode(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}
