import '../claude_client.dart';
import '../ebay_client.dart';
import '../net.dart';
import '../settings.dart';
import '../web_fetcher.dart';
import 'listing_reader.dart';

/// Rough selling costs used for the "est. net" line. Doug's listings charge
/// the buyer $4.99 Media Mail; comps are compared on buyer total, so net =
/// total - eBay fees - label.
class SellCosts {
  static const feeRate = 0.136; // eBay final value fee incl. shipping
  static const feeFixed = 0.40; // per-order fee
  static const label = 4.39; // Media Mail label
  static const lotTargetPerDisc = 1.00; // landed cost target for lots

  static double net(double buyerTotal) {
    final n = buyerTotal * (1 - feeRate) - feeFixed - label;
    return n < 0 ? 0 : n;
  }
}

class CompSale {
  final String date;
  final String title;
  final double? price;
  final double? shipping;
  final double? total;
  final String condition;
  CompSale(this.date, this.title, this.price, this.shipping, this.total, this.condition);

  factory CompSale.fromJson(Map<String, dynamic> j) => CompSale(
        (j['date'] ?? '').toString(),
        (j['title'] ?? '').toString(),
        _num(j['price']),
        _num(j['shipping']),
        _num(j['total']),
        (j['condition'] ?? '').toString(),
      );
}

double? _num(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().replaceAll(RegExp(r'[^\d.]'), ''));
}

class ItemComp {
  final String name;
  final String format;
  final String edition;
  final String query;
  final String compCondition;
  final String soldUrl;
  List<CompSale> sales = [];
  String trend = '';
  double? level; // current buyer-total selling level
  String confidence = 'pending'; // good | thin | none | error | pending
  String note = '';

  ItemComp({
    required this.name,
    required this.format,
    required this.edition,
    required this.query,
    required this.compCondition,
    required this.soldUrl,
  });

  double get net => level == null ? 0 : SellCosts.net(level!);
}

class RedFlag {
  final bool stop;
  final String text;
  RedFlag(this.stop, this.text);
}

enum CompsVerdict { pass, good, thin, no, noComps }

class CompsReport {
  final ListingSnapshot listing;
  String title = '';
  String summary = '';
  String condition = '';
  String seller = '';
  bool auction = false;
  String auctionNote = '';
  double? price;
  double? shipping;
  bool shippingAssumed = false;
  List<ItemComp> items = [];
  List<RedFlag> flags = [];
  int unidentified = 0;
  String? error;

  CompsReport(this.listing);

  double? get cost => price == null ? null : price! + (shipping ?? 0);
  List<ItemComp> get valued => items.where((i) => i.level != null).toList();
  double get totalLevel => valued.fold(0, (a, i) => a + i.level!);
  double get totalNet => valued.fold(0, (a, i) => a + i.net);
  int get discCount => items.length + unidentified;
  double? get perDisc => (cost == null || discCount == 0) ? null : cost! / discCount;
  bool get hasStop => flags.any((f) => f.stop);

  CompsVerdict get verdict {
    if (hasStop) return CompsVerdict.pass;
    if (valued.isEmpty || cost == null) return CompsVerdict.noComps;
    final c = cost!;
    final n = totalNet;
    if (n >= 2 * c && n >= c + 15) return CompsVerdict.good;
    if (n >= c * 1.3) return CompsVerdict.thin;
    return CompsVerdict.no;
  }

  String get verdictText {
    switch (verdict) {
      case CompsVerdict.pass:
        return 'PASS — red flag';
      case CompsVerdict.good:
        return 'Looks like a money maker';
      case CompsVerdict.thin:
        return 'Thin — small margin';
      case CompsVerdict.no:
        return 'Not worth it at this price';
      case CompsVerdict.noComps:
        return 'Not enough sold comps to call it';
    }
  }
}

class CompEngine {
  final AppSettings settings;
  final void Function(String) onProgress;
  final void Function() onUpdate;
  bool _cancelled = false;

  CompEngine({required this.settings, required this.onProgress, required this.onUpdate});

  void cancel() => _cancelled = true;

  static const _planSystem = '''
You read ONE eBay or Vinted listing for a US media reseller (CDs, DVDs, Blu-ray, 4K, cassettes, vinyl) who is deciding whether to BUY it to resell on eBay. Report facts only; never suggest list prices.

1. Extract the cost to buy it now: for Buy It Now, the price; for an auction, the current bid (or the starting bid if no bids). Shipping to a US buyer: the shipping charge shown (0 if free; null if not shown). For Vinted, use the price shown including the buyer protection fee if that is visible; Vinted shipping is added at checkout, so use null unless a shipping price is shown.

2. List every distinct title being sold. A single item is one entry. A lot is one entry per title, taken from the title, item specifics and description. If the listing says how many items there are but does not name them all, list the ones you can identify and put the rest in "unidentified". At most 25 entries.
For each title:
- name: "Artist - Album" for music, the movie or show title for video
- format: CD, DVD, Blu-ray, 4K, Cassette, Vinyl or Other
- edition: short notes that change value (sealed, numbered/limited run like 62/100, box set, steelbook, full screen, promo, import). Empty if none.
- ebay_query: words for an eBay Sold Items search that pin down the exact title, format and edition. Always include the format word (cassette, cd, dvd, blu-ray, 4k, vinyl). Keep it short (3-8 words); no condition words.
- comp_condition: "sealed" if this copy is sealed/new, otherwise "used".

3. Red flags. "stop" means do not buy this to resell; "warn" means be careful.
- stop: hate or extremist media, e.g. National Socialist black metal (NSBM), white-power / RAC bands or labels (Resistance Records and similar), Nazi imagery, 14/88 codes. eBay's Offensive Materials policy bans media identified as Nazi propaganda and Vinted bans hate content, so these cannot be resold safely. Name the exact titles or bands and say why. Only use stop when you are confident; if you only suspect it, use warn and say it is unconfirmed.
- stop: bootleg or counterfeit signs (unofficial pressings, CD-R copies, "reproduction", several identical "sealed" copies from one seller, titles that were never released in that format).
- warn: DVD lots or CD lots (he is not buying DVDs unless they are very valuable and is slowing down on CDs); full-screen DVDs; no returns on a lot with unclear condition; contents not visible or not listed; "for promotional use only" copies; auctions with a long time left (price will rise).

Return ONLY JSON, no prose:
{"title":"<listing title>","summary":"<one line: what is for sale>","price":<number or null>,"shipping":<number or null>,"auction":true|false,"auction_note":"<bids and time left, or empty>","condition":"<as listed>","seller":"<name and feedback if shown>","items":[{"name":"","format":"","edition":"","ebay_query":"","comp_condition":"sealed|used"}],"unidentified":<int>,"red_flags":[{"level":"stop|warn","text":"..."}]}''';

  static const itemSystem = '''
You read eBay Sold Items search results for ONE title for a US media reseller. Never use Terapeak-style estimates; use only the sold listings in the text. Never suggest list prices.

RULES
1. Use only sales of the SAME title, format and edition. Ignore other formats (a CD sale is not a cassette comp), other editions (steelbook vs standard, limited vs regular), lots or bundles, imports priced in other currencies, empty cases, and anything under "Results matching fewer words" unless nothing else matches.
2. Match condition: a sealed copy is comped against Brand New / sealed sales only; a used copy against Pre-Owned sales only.
3. Buyer total = item price + delivery charge (free delivery = 0). Always report totals.
4. Read the TREND, not the median: put the sales in date order, newest first. If the newest sales are stepping down from older ones, the current level is the most recent one or two sales. If flat or rising, say so.
5. current_level = the buyer total this copy would most likely sell for now, from the newest same-edition sales. null if there are no usable same-edition sales.
6. confidence: "good" = 3 or more same-edition sales in the last 90 days; "thin" = 1-2 sales, or only older sales; "none" = no usable sales.

Return ONLY JSON:
{"comps":[{"date":"Oct 29, 2026","title":"...","price":0.0,"shipping":0.0,"total":0.0,"condition":"Brand New|Pre-Owned"}],"trend":"<one line>","current_level":<number or null>,"confidence":"good|thin|none","note":"<one line: anything that matters, e.g. only sealed copies sold, edition unclear>"}
List at most 8 comps, newest first, same-edition only.''';

  Future<CompsReport> run(String sharedText) async {
    final session = BrowserSession();
    final web = WebFetcher();
    final reader = ListingReader(session, web: web);
    final ebay = EbayClient(session, web: web);
    final claude = ClaudeClient(session, apiKey: settings.apiKey, model: settings.model);
    ListingSnapshot snap;
    try {
      onProgress('Opening the listing…');
      snap = await reader.read(sharedText);
    } catch (e) {
      session.close();
      rethrow;
    }
    final report = CompsReport(snap);
    try {
      onProgress('Reading the ${snap.sourceName} listing (${snap.id})…');
      final planText = await claude.ask(
        _planSystem,
        'SOURCE: ${snap.sourceName}\nURL: ${snap.url}\n\nLISTING PAGE TEXT:\n${snap.pageText}\n\n'
        'SELLER DESCRIPTION:\n${snap.descriptionText.isEmpty ? '(none)' : snap.descriptionText}',
        maxTokens: 6000,
      );
      final plan = ClaudeClient.extractJson(planText);
      report.title = (plan['title'] ?? '').toString();
      report.summary = (plan['summary'] ?? '').toString();
      report.condition = (plan['condition'] ?? '').toString();
      report.seller = (plan['seller'] ?? '').toString();
      report.auction = plan['auction'] == true;
      report.auctionNote = (plan['auction_note'] ?? '').toString();
      report.price = _num(plan['price']);
      report.shipping = _num(plan['shipping']);
      if (report.shipping == null) {
        report.shipping = settings.shippingAssumption;
        report.shippingAssumed = true;
      }
      report.unidentified = (plan['unidentified'] as num?)?.toInt() ?? 0;
      for (final f in (plan['red_flags'] as List? ?? const [])) {
        if (f is Map) {
          report.flags.add(RedFlag(f['level'] == 'stop', (f['text'] ?? '').toString()));
        }
      }
      for (final it in (plan['items'] as List? ?? const [])) {
        if (it is! Map) continue;
        final q = (it['ebay_query'] ?? it['name'] ?? '').toString().trim();
        if (q.isEmpty) continue;
        final cond = it['comp_condition'] == 'sealed' ? 'sealed' : 'used';
        report.items.add(ItemComp(
          name: (it['name'] ?? q).toString(),
          format: (it['format'] ?? '').toString(),
          edition: (it['edition'] ?? '').toString(),
          query: q,
          compCondition: cond,
          soldUrl: EbayClient.soldSearchUri(q, compCondition: cond).toString(),
        ));
      }
      onUpdate();

      if (report.hasStop) {
        onProgress('Red flag found — skipping comps.');
        return report;
      }

      for (var i = 0; i < report.items.length; i++) {
        if (_cancelled) break;
        final item = report.items[i];
        onProgress('Comping ${i + 1}/${report.items.length}: ${item.name}');
        String soldText;
        try {
          soldText = await ebay.soldSearchText(item.query, compCondition: item.compCondition);
        } on EbayException catch (e) {
          final msg = e.message;
          if (msg.contains('no sold listings')) {
            item.confidence = 'none';
            item.note = 'No sold results for this search.';
          } else {
            item.confidence = 'error';
            item.note = msg;
          }
          onUpdate();
          continue;
        }
        try {
          final t = await claude.ask(
            itemSystem,
            'TITLE: ${item.name}\nFORMAT: ${item.format}\nEDITION: ${item.edition.isEmpty ? '(standard)' : item.edition}\n'
            'COPY CONDITION: ${item.compCondition == 'sealed' ? 'sealed / new' : 'used'}\n\n'
            'EBAY SOLD ITEMS SEARCH TEXT (query: ${item.query})\n$soldText',
            maxTokens: 3000,
          );
          final j = ClaudeClient.extractJson(t);
          item.sales = (j['comps'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(CompSale.fromJson)
              .toList();
          item.trend = (j['trend'] ?? '').toString();
          item.level = _num(j['current_level']);
          item.confidence = (j['confidence'] ?? (item.level == null ? 'none' : 'thin')).toString();
          item.note = (j['note'] ?? '').toString();
        } catch (e) {
          item.confidence = 'error';
          item.note = 'Could not read comps: $e';
        }
        onUpdate();
      }
      onProgress(_cancelled ? 'Stopped.' : 'Done.');
    } catch (e) {
      report.error = e.toString();
      onProgress('Error: $e');
    } finally {
      session.close();
    }
    return report;
  }
}
