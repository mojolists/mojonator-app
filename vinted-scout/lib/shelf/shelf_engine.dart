import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../claude_client.dart';
import '../comps/comp_engine.dart';
import '../ebay_client.dart';
import '../net.dart';
import '../settings.dart';
import '../web_fetcher.dart';
import 'price_db.dart';

/// Per-item money math for a shelf find. Buyer pays $4.99 shipping on Garage
/// listings, so comps are buyer totals; net takes off eBay fees, the label and
/// packaging. Cost is the shelf price plus Texas sales tax.
class ShelfMath {
  static const feeRate = 0.136;
  static const feeFixed = 0.40;
  static const label = 4.39;
  static const taxRate = 0.0825;
  static const targetProfit = 2.00;

  static double net(double buyerTotal, double packaging) =>
      buyerTotal * (1 - feeRate) - feeFixed - label - packaging;

  static double cost(double shelfPrice) => shelfPrice * (1 + taxRate);
}

enum ShelfVerdict { buy, maybe, skip, stop, pending, error }

class ShelfItem {
  final String name;
  final String format;
  final String edition;
  final String query;
  final String compCondition;
  final String readConfidence; // sure | unsure
  final String tier; // likely | maybe | unlikely
  final String flag; // '' or a red-flag reason
  final bool stop;
  final String soldUrl;

  // Filled in as the check runs.
  String status = 'Waiting…';
  bool fromDb = false;
  int dbAgeDays = 0;
  double? level;
  String confidence = 'pending';
  String trend = '';
  String note = '';
  List<CompSale> sales = [];
  bool done = false;
  bool failed = false;

  ShelfItem({
    required this.name,
    required this.format,
    required this.edition,
    required this.query,
    required this.compCondition,
    required this.readConfidence,
    required this.tier,
    required this.flag,
    required this.stop,
    required this.soldUrl,
  });

  double? profit(double shelfPrice, double packaging) => level == null
      ? null
      : ShelfMath.net(level!, packaging) - ShelfMath.cost(shelfPrice);

  ShelfVerdict verdict(double shelfPrice, double packaging) {
    if (stop) return ShelfVerdict.stop;
    if (failed) return ShelfVerdict.error;
    if (!done) return ShelfVerdict.pending;
    final p = profit(shelfPrice, packaging);
    if (p == null) return ShelfVerdict.skip;
    if (p >= ShelfMath.targetProfit && confidence == 'good') return ShelfVerdict.buy;
    if (p >= ShelfMath.targetProfit || p >= 1.0) return ShelfVerdict.maybe;
    return ShelfVerdict.skip;
  }
}

class ShelfReport {
  String summary = '';
  int unreadable = 0;
  List<ShelfItem> items = [];
  String? error;
}

class ShelfEngine {
  final AppSettings settings;
  final PriceDb db;
  final void Function(String) onProgress;
  final void Function() onUpdate;
  final ShelfReport report = ShelfReport();
  bool _cancelled = false;

  ShelfEngine({
    required this.settings,
    required this.db,
    required this.onProgress,
    required this.onUpdate,
  });

  void cancel() => _cancelled = true;
  bool get cancelled => _cancelled;

  static const _readSystem = '''
You look at ONE photo of physical media (a store shelf, a box, a crate, a table, or a photo of a lot) for a US reseller who buys discs and tapes to resell on eBay. Read every title you can see on spines and covers. Report facts only; never suggest prices.

For each distinct title:
- name: "Artist - Album" for music, the movie or show title for video
- format: CD, DVD, Blu-ray, 4K, Cassette, Vinyl, VHS or Other (from the case shape, spine logo and size: Blu-ray cases are blue and shorter, 4K cases are black with a 4K UHD band, DVD cases are taller black/clear, CDs are jewel cases)
- edition: short notes that change value, only when visible: steelbook, box set, complete series, Criterion / Arrow / Shout Factory / Scream Factory / Vinegar Syndrome / Kino / 88 Films / other boutique label, limited/numbered, slipcover, sealed, full screen, 2-disc special edition. Empty if none.
- ebay_query: 3-8 words for an eBay Sold Items search that pin down this exact title, format and edition. Always include the format word (cd, dvd, blu-ray, 4k, cassette, vinyl). No condition words.
- comp_condition: "sealed" only if shrink-wrap is visible on that copy, otherwise "used".
- read: "sure" if the title is clearly legible; "unsure" if you are partly guessing (blurry, cut off, angled, small text).
- tier: how likely this title is to be worth reselling, from what sells for him:
  "likely" = boutique/collector labels, box sets and complete series, steelbooks, Doctor Who, name-brand horror and cult films, concert discs, anime sets, out-of-print titles, films from before 2010 on Blu-ray, sealed 80s-90s cassettes, rare hip-hop/metal/soundtrack tapes.
  "unlikely" = recent mainstream films (2015 and later, wide releases), kids/Disney/Pixar, single TV seasons, common greatest-hits CDs, fitness and religious discs, DVDs of common films.
  "maybe" = everything else.
- flag: "" normally. "stop" text if the item is hate/extremist media (NSBM, white-power bands or labels, Nazi imagery) or clearly a bootleg/counterfeit (CD-R, homemade art). "warn" text for anything else worth checking (DVD of a common film, library copy, no case, empty case visible).

Count spines or covers you can see but cannot read at all as "unreadable". Do not invent titles. List each title once even if there are several copies (mention copies in edition, e.g. "2 copies"). At most 80 titles.

Return ONLY JSON:
{"summary":"<one line: what the photo shows and roughly how many items>","unreadable":<int>,"items":[{"name":"","format":"","edition":"","ebay_query":"","comp_condition":"sealed|used","read":"sure|unsure","tier":"likely|maybe|unlikely","flag_level":"|stop|warn","flag":""}]}''';

  /// Shrink a phone photo to something the API accepts and reads well.
  static Future<Uint8List> prepareImage(Uint8List bytes) async {
    return compute(_shrink, bytes);
  }

  static Uint8List _shrink(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    var im = img.bakeOrientation(decoded);
    const maxEdge = 2400;
    final longEdge = im.width > im.height ? im.width : im.height;
    if (longEdge > maxEdge) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxEdge, interpolation: img.Interpolation.average)
          : img.copyResize(im, height: maxEdge, interpolation: img.Interpolation.average);
    }
    var q = 85;
    var out = img.encodeJpg(im, quality: q);
    while (out.length > 3800000 && q > 50) {
      q -= 10;
      out = img.encodeJpg(im, quality: q);
    }
    return out;
  }

  Future<ShelfReport> run(Uint8List photo) async {
    final session = BrowserSession();
    final claude = ClaudeClient(session, apiKey: settings.apiKey, model: settings.model);
    try {
      await db.load();
      onProgress('Preparing the photo…');
      final jpg = await prepareImage(photo);
      onProgress('Reading titles off the photo…');
      final text = await claude.askWithImage(
        _readSystem,
        'Read every title in this photo.',
        jpg,
        maxTokens: 12000,
      );
      final j = ClaudeClient.extractJson(text);
      report.summary = (j['summary'] ?? '').toString();
      report.unreadable = (j['unreadable'] as num?)?.toInt() ?? 0;
      for (final it in (j['items'] as List? ?? const [])) {
        if (it is! Map) continue;
        final q = (it['ebay_query'] ?? it['name'] ?? '').toString().trim();
        if (q.isEmpty) continue;
        final cond = it['comp_condition'] == 'sealed' ? 'sealed' : 'used';
        final level = (it['flag_level'] ?? '').toString();
        report.items.add(ShelfItem(
          name: (it['name'] ?? q).toString(),
          format: (it['format'] ?? '').toString(),
          edition: (it['edition'] ?? '').toString(),
          query: q,
          compCondition: cond,
          readConfidence: it['read'] == 'unsure' ? 'unsure' : 'sure',
          tier: const ['likely', 'maybe', 'unlikely'].contains(it['tier']) ? it['tier'] as String : 'maybe',
          flag: (it['flag'] ?? '').toString(),
          stop: level == 'stop',
          soldUrl: EbayClient.soldSearchUri(q, compCondition: cond).toString(),
        ));
      }
      if (report.items.isEmpty) {
        report.error = report.unreadable > 0
            ? 'Could not read any titles (${report.unreadable} too blurry or small). Try a closer, sharper photo.'
            : 'No titles found in that photo.';
        return report;
      }

      // Database first: instant answers.
      var hits = 0;
      for (final it in report.items) {
        if (it.stop) {
          it.done = true;
          it.status = 'Red flag — not comped';
          continue;
        }
        final e = db.fresh(it.query, it.compCondition);
        if (e != null) {
          it.fromDb = true;
          it.dbAgeDays = e.ageDays;
          it.level = e.level;
          it.confidence = e.confidence;
          it.trend = e.trend;
          it.done = true;
          it.status = 'From price database (${e.ageDays == 0 ? 'today' : '${e.ageDays}d old'})';
          hits++;
        }
      }
      onUpdate();

      // Then live comps, most promising first, two at a time.
      const rank = {'likely': 0, 'maybe': 1, 'unlikely': 2};
      final queue = report.items.where((i) => !i.done).toList()
        ..sort((a, b) => rank[a.tier]!.compareTo(rank[b.tier]!));
      final total = queue.length;
      var started = 0;
      onProgress('${report.items.length} titles · $hits from the database · comping $total on eBay…');

      Future<void> worker() async {
        final ebay = EbayClient(session, web: WebFetcher());
        while (!_cancelled) {
          if (queue.isEmpty) return;
          final it = queue.removeAt(0);
          started++;
          onProgress('Comping $started/$total: ${it.name}');
          it.status = 'Comping on eBay…';
          onUpdate();
          await _comp(it, ebay, claude);
          onUpdate();
        }
      }

      await Future.wait([worker(), worker()]);
      for (final it in report.items.where((i) => !i.done && !i.failed)) {
        it.status = 'Not comped (stopped)';
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

  Future<void> _comp(ShelfItem it, EbayClient ebay, ClaudeClient claude) async {
    String soldText;
    try {
      soldText = await ebay.soldSearchText(it.query, compCondition: it.compCondition);
    } on EbayException catch (e) {
      if (e.message.contains('no sold listings')) {
        it.confidence = 'none';
        it.note = 'No sold results for this search.';
        it.done = true;
        it.status = 'No sold comps';
        await _save(it);
      } else {
        it.failed = true;
        it.note = e.message;
        it.status = 'eBay error';
      }
      return;
    }
    try {
      final t = await claude.ask(
        CompEngine.itemSystem,
        'TITLE: ${it.name}\nFORMAT: ${it.format}\nEDITION: ${it.edition.isEmpty ? '(standard)' : it.edition}\n'
        'COPY CONDITION: ${it.compCondition == 'sealed' ? 'sealed / new' : 'used'}\n\n'
        'EBAY SOLD ITEMS SEARCH TEXT (query: ${it.query})\n$soldText',
        maxTokens: 3000,
      );
      final j = ClaudeClient.extractJson(t);
      it.sales = (j['comps'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CompSale.fromJson)
          .toList();
      it.trend = (j['trend'] ?? '').toString();
      final lv = j['current_level'];
      it.level = lv is num ? lv.toDouble() : double.tryParse('${lv ?? ''}');
      it.confidence = (j['confidence'] ?? (it.level == null ? 'none' : 'thin')).toString();
      it.note = (j['note'] ?? '').toString();
      it.done = true;
      it.status = 'Comped just now';
      await _save(it);
    } catch (e) {
      it.failed = true;
      it.note = 'Could not read comps: $e';
      it.status = 'Error';
    }
  }

  Future<void> _save(ShelfItem it) => db.put(PriceEntry(
        key: PriceDb.keyFor(it.query, it.compCondition),
        name: it.name,
        format: it.format,
        query: it.query,
        condition: it.compCondition,
        level: it.level,
        confidence: it.confidence,
        trend: it.trend,
        saleCount: it.sales.length,
        checked: DateTime.now(),
      ));
}
