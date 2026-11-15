import '../net.dart';
import '../web_fetcher.dart';

class ListingException implements Exception {
  final String message;
  ListingException(this.message);
  @override
  String toString() => message;
}

enum ListingSource { ebay, vinted }

/// What we know about the listing the user shared, as plain text for Claude.
class ListingSnapshot {
  final ListingSource source;
  final String id;
  final String url;
  final String pageText;
  final String descriptionText;
  ListingSnapshot({
    required this.source,
    required this.id,
    required this.url,
    required this.pageText,
    required this.descriptionText,
  });

  String get sourceName => source == ListingSource.ebay ? 'eBay' : 'Vinted';
}

/// Where a shared text points: an eBay item, a Vinted item, or a link that
/// still has to be followed (eBay app share links are short ebay.us links).
class ListingRef {
  final ListingSource? source;
  final String? id;
  final Uri? link;
  ListingRef({this.source, this.id, this.link});
}

class ListingReader {
  final BrowserSession session;
  final WebFetcher web;
  ListingReader(this.session, {WebFetcher? web}) : web = web ?? WebFetcher();

  static final _url = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);
  static final _ebayItem = RegExp(r'/itm/(?:[^/?#]*/)?(\d{9,14})');
  static final _ebayItemQuery = RegExp(r'[?&](?:item|itemId|itm)=(\d{9,14})');
  static final _vintedItem = RegExp(r'/items/(\d{6,14})');
  static final _bareNumber = RegExp(r'\b(\d{11,13})\b');

  /// Parse whatever was shared or pasted: a link, share text containing a
  /// link, or a bare eBay item number.
  static ListingRef parse(String input) {
    final text = input.trim();
    for (final m in _url.allMatches(text)) {
      final raw = m.group(0)!.replaceAll(RegExp(r'[).,;!]+$'), '');
      final uri = Uri.tryParse(raw);
      if (uri == null) continue;
      final r = fromUri(uri);
      if (r != null) return r;
    }
    final n = _bareNumber.firstMatch(text);
    if (n != null) return ListingRef(source: ListingSource.ebay, id: n.group(1));
    throw ListingException(
        'Could not find an eBay or Vinted listing in that text. Share the listing '
        'from the eBay or Vinted app, or paste its link or eBay item number.');
  }

  static ListingRef? fromUri(Uri uri) {
    final host = uri.host.toLowerCase();
    final whole = uri.toString();
    if (host.contains('vinted.')) {
      final m = _vintedItem.firstMatch(uri.path);
      if (m != null) return ListingRef(source: ListingSource.vinted, id: m.group(1));
      return ListingRef(link: uri);
    }
    if (host.contains('ebay.')) {
      final m = _ebayItem.firstMatch(uri.path) ?? _ebayItemQuery.firstMatch(whole);
      if (m != null) return ListingRef(source: ListingSource.ebay, id: m.group(1));
      // ebay.us / ebay.to short links and other eBay pages: follow them.
      return ListingRef(link: uri);
    }
    return null;
  }

  /// Follow a short link to the real item URL.
  Future<ListingRef> resolve(ListingRef ref) async {
    if (ref.id != null) return ref;
    final link = ref.link!;
    // Plain HTTP redirects first (cheap), then a real browser load.
    try {
      final r = await session.get(link, maxRedirects: 8);
      final found = fromUri(r.finalUri);
      if (found != null && found.id != null) return found;
      final inBody = _url
          .allMatches(r.body)
          .map((m) => Uri.tryParse(m.group(0)!))
          .whereType<Uri>()
          .map(fromUri)
          .whereType<ListingRef>()
          .where((x) => x.id != null);
      if (inBody.isNotEmpty) return inBody.first;
    } catch (_) {}
    try {
      await web.pageText(link.toString(), settlePolls: 2);
      final last = web.lastUrl == null ? null : Uri.tryParse(web.lastUrl!);
      final found = last == null ? null : fromUri(last);
      if (found != null && found.id != null) return found;
    } catch (_) {}
    throw ListingException('Could not open that link to find the listing: $link');
  }

  Future<ListingSnapshot> read(String input) async {
    final ref = await resolve(parse(input));
    if (ref.source == ListingSource.vinted) return _vinted(ref.id!);
    return _ebay(ref.id!);
  }

  Future<ListingSnapshot> _ebay(String id) async {
    final url = 'https://www.ebay.com/itm/$id';
    String page;
    try {
      page = await web.pageText(url, readyWhen: RegExp('item number', caseSensitive: false));
    } catch (e) {
      final r = await session.get(Uri.parse(url));
      if (!r.ok) throw ListingException('Could not open the eBay listing (HTTP ${r.status}).');
      page = htmlToText(r.body);
      if (WebFetcher.isChallenge(page)) {
        throw ListingException('eBay showed a bot check instead of the listing. Try again in a minute.');
      }
    }
    page = _ebayCore(page);
    String desc = '';
    try {
      final r = await session.get(Uri.parse('https://itm.ebaydesc.com/itmdesc/$id'));
      if (r.ok) desc = htmlToText(r.body);
    } catch (_) {}
    if (desc.trim().isEmpty) {
      try {
        desc = await web.pageText('https://itm.ebaydesc.com/itmdesc/$id', settlePolls: 2);
      } catch (_) {}
    }
    return ListingSnapshot(
      source: ListingSource.ebay,
      id: id,
      url: url,
      pageText: _cap(page, 7000),
      descriptionText: _cap(desc, 6000),
    );
  }

  /// Keep the part of the item page that describes the item: from the title
  /// down to the seller feedback block (skips menus and recommendations).
  static String _ebayCore(String text) {
    var t = text.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n+'), '\n');
    final cats = t.indexOf('Everything Else');
    if (cats > 0 && cats < 4000) t = t.substring(cats + 'Everything Else'.length);
    final end = t.indexOf(RegExp(r'Seller feedback \(|Detailed seller ratings|Explore related'));
    if (end > 500) t = t.substring(0, end);
    return t;
  }

  Future<ListingSnapshot> _vinted(String id) async {
    final url = 'https://www.vinted.com/items/$id';
    String page = '';
    try {
      page = await web.pageText(url, readyWhen: RegExp(r'\$\s?\d'));
    } catch (_) {
      final r = await session.get(Uri.parse(url));
      if (!r.ok) throw ListingException('Could not open the Vinted listing (HTTP ${r.status}).');
      page = htmlToText(r.body);
    }
    var t = page.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n+'), '\n');
    // Vinted puts nav and "Member's items"/"Similar items" headings above the
    // item block, and "Shop and sell safely" right after it.
    final end = t.indexOf('Shop and sell safely');
    if (end > 300) t = t.substring(end > 6500 ? end - 6500 : 0, end);
    return ListingSnapshot(
      source: ListingSource.vinted,
      id: id,
      url: url,
      pageText: _cap(t, 7000),
      descriptionText: '',
    );
  }

  static String _cap(String s, int n) => s.length <= n ? s : s.substring(0, n);
}
