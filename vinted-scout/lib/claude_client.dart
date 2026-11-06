import 'dart:convert';

import 'models.dart';
import 'net.dart';

class ClaudeException implements Exception {
  final String message;
  ClaudeException(this.message);
  @override
  String toString() => message;
}

class ClaudeClient {
  final BrowserSession session;
  final String apiKey;
  final String model;
  ClaudeClient(this.session, {required this.apiKey, required this.model});

  Future<String> _ask(String system, String user, {int maxTokens = 4000}) async {
    final r = await session.postJson(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      {
        'model': model,
        'max_tokens': maxTokens,
        'system': system,
        'messages': [
          {'role': 'user', 'content': user}
        ],
      },
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
    );
    if (!r.ok) {
      String detail = r.body;
      try {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        detail = (j['error']?['message'] ?? r.body).toString();
      } catch (_) {}
      if (r.status == 401) {
        throw ClaudeException('Claude API key rejected (401). Check the key in Settings.');
      }
      throw ClaudeException('Claude API error ${r.status}: $detail');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final content = j['content'] as List? ?? const [];
    final buf = StringBuffer();
    for (final c in content) {
      if (c is Map && c['type'] == 'text') buf.write(c['text']);
    }
    return buf.toString();
  }

  static Map<String, dynamic> _extractJson(String text) {
    var s = text.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(s);
    if (fence != null) s = fence.group(1)!.trim();
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start >= 0 && end > start) s = s.substring(start, end + 1);
    return jsonDecode(s) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------- Stage 1

  static const _pickSystem = '''
You help a US eBay media reseller (Blu-ray, 4K, CD, cassette) spot Vinted listings he can buy and resell on eBay at a clear profit. You are choosing which newly listed items are worth comping on eBay. Report only; never suggest list prices.

KEEP (worth comping): box sets, complete-series sets, OOP or boutique-label editions (Arrow, Criterion, Vinegar Syndrome, Scream/Shout Factory, Kino, Vestron, Severin, 88 Films, Indicator), collector/limited steelbooks (Manta Lab, Blufans, Zavvi, Best Buy exclusives), anime complete collections, multi-disc music boxes, sealed 80s-90s cassettes, limited modern cassette runs, audiobook cassette sets, rare hip-hop/metal/soundtrack cassettes, and anything priced far below what a sealed copy fetches.

SKIP: landed cost under the minimum given; common titles (recent Disney/Pixar/kids, single TV seasons, current pop CDs, Taylor Swift / Target-exclusive variants, K-pop, bootleg-looking "sealed" tapes from sellers with many copies); untitled or vague listings ("Blu-ray movies", "Cassette tapes"); replacement cases; blank media; electronics, clothing, books, VHS, 8-track; mixed-condition bundles; region-B/UK imports; DVDs (he is not buying DVDs unless very valuable); items listed by a seller at obvious retail (e.g. a run of identical "\$40 Brand New Arrow" discs).

For each pick, write the eBay Sold Items search query: the title words that identify the exact edition and format, including the label/edition words (e.g. "prestige manta lab steelbook", "burst angel complete collection blu-ray", "harry potter cassette 1-7 jim dale"). Set comp_condition to "sealed" when the Vinted condition is New with tags / New without tags or the title/description says sealed; "used" for Very good. A cassette must be comped against cassette sales, never CD.

Return ONLY JSON: {"candidates":[{"id":<vinted id>,"why":"<one line>","ebay_query":"<query>","comp_condition":"sealed"|"used"}]} with at most the number of candidates requested, best first.''';

  Future<List<Map<String, dynamic>>> pickCandidates({
    required List<VintedListing> listings,
    required int maxCandidates,
    required double minLanded,
    required double shippingAssumption,
    required String extraRules,
  }) async {
    final lines = listings.map((l) => l.compactLine).join('\n');
    final user = '''
Landed cost = the "incl" price + \$${shippingAssumption.toStringAsFixed(2)} shipping. Skip anything whose landed cost is under \$${minLanded.toStringAsFixed(2)}.
${extraRules.trim().isEmpty ? '' : 'Extra rules from the reseller:\n${extraRules.trim()}\n'}
Pick up to $maxCandidates candidates from these ${listings.length} Vinted listings (id | format | condition | incl price | title):

$lines''';
    final text = await _ask(_pickSystem, user, maxTokens: 2500);
    final j = _extractJson(text);
    final list = (j['candidates'] as List?) ?? const [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  // ---------------------------------------------------------------- Stage 2

  static const _compSystem = '''
You read eBay Sold Items results for a US media reseller and decide whether a Vinted listing is a resale deal. Never use Terapeak-style estimates; only the sold listings in the text. Never suggest list prices.

RULES
1. Use only comps of the SAME edition and format as the Vinted item. Ignore 4K vs Blu-ray mismatches, steelbooks vs standard, limited editions with extras, imports priced in other currencies, CD comps for a cassette, lots/bundles unless the Vinted item is the same lot, empty boxes, and anything under "Results matching fewer words" unless nothing else matches.
2. Match condition: a sealed Vinted item is comped against Brand New / sealed sales only; a "Very good" Vinted item against Pre-Owned sales only.
3. Buyer total = item price + delivery charge (free delivery = +0). Always report totals.
4. CRITICAL - read the TREND, not the median: list the sales in date order (newest first) and look at where the price is heading. If the newest sales are stepping down from older ones, the current level is the most recent one or two sales, not the window's middle. If they are stepping up or flat, say so.
5. Verdict "deal" only if the CURRENT selling level is at least DOUBLE the Vinted landed cost AND at least \$15 above it. "borderline" if it is within about 10% of clearing that bar, or the bar is cleared on one thin/old comp. Otherwise "no". If the text contains no usable same-edition comps, verdict "no" with reason "no usable comps" and current_level null.
6. Caveats to raise: single or stale comp, softening price, unclear edition, Vinted seller with few reviews, title/condition mismatch (e.g. listed Very good but described as sealed).

Return ONLY JSON:
{"comps":[{"date":"Oct 29, 2026","title":"...","price":0.0,"shipping":0.0,"total":0.0,"condition":"Brand New|Pre-Owned|New (Other)","same_edition":true}],
 "trend":"<one line>","current_level":<number or null>,"verdict":"deal|borderline|no","reason":"<one or two lines>","caveats":["..."]}
List at most 12 comps, newest first, same-edition ones first.''';

  Future<Map<String, dynamic>> readComps({
    required Candidate c,
    required double landedCost,
    required String ebayText,
    required VintedItemDetail? detail,
    required String extraRules,
  }) async {
    final l = c.listing;
    final desc = detail == null
        ? ''
        : '''
Vinted description: ${detail.description.replaceAll('\n', ' ').trim()}
Vinted seller: ${detail.sellerLogin} (${detail.sellerFeedbackCount} reviews)${detail.freeShipping == true ? ', free shipping' : ''}
''';
    final user = '''
VINTED ITEM
Title: ${l.title}
Format searched: ${l.format}
Vinted condition: ${l.condition}
Price: \$${l.price.toStringAsFixed(2)} (\$${l.inclPrice.toStringAsFixed(2)} incl. fee); landed cost used for the test: \$${landedCost.toStringAsFixed(2)}
Comp against: ${c.compCondition == 'sealed' ? 'sealed / Brand New sales' : 'Pre-Owned sales'}
$desc${extraRules.trim().isEmpty ? '' : 'Extra rules from the reseller:\n${extraRules.trim()}\n'}
EBAY SOLD ITEMS SEARCH TEXT (query: ${c.ebayQuery})
$ebayText''';
    final text = await _ask(_compSystem, user, maxTokens: 3000);
    return _extractJson(text);
  }
}
