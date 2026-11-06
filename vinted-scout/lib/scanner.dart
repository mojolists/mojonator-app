import 'claude_client.dart';
import 'ebay_client.dart';
import 'models.dart';
import 'net.dart';
import 'settings.dart';
import 'vinted_client.dart';

typedef ProgressFn = void Function(String message);

/// The on-demand scan: Vinted pages -> Claude picks candidates -> eBay sold
/// text per candidate -> Claude reads the trend -> verdicts.
class Scanner {
  final AppSettings settings;
  final List<SeenItem> seen;
  final ProgressFn onProgress;
  bool _cancelled = false;

  Scanner({required this.settings, required this.seen, required this.onProgress});

  void cancel() => _cancelled = true;

  Future<ScanResult> run() async {
    final started = DateTime.now();
    final log = <String>[];
    void say(String m) {
      log.add(m);
      onProgress(m);
    }

    final session = BrowserSession();
    final vinted = VintedClient(session);
    final ebay = EbayClient(session);
    final claude = ClaudeClient(session,
        apiKey: settings.apiKey.trim(), model: settings.model.trim());

    final results = <CandidateResult>[];
    var listingsRead = 0;
    var pagesRead = 0;
    String? fatal;

    try {
      if (!settings.hasKey) {
        throw ClaudeException('No Claude API key set. Add it in Settings.');
      }

      // ------------------------------------------------------------ Vinted
      final all = <int, VintedListing>{};
      final searches = settings.searches.where((s) => s.enabled).toList();
      if (searches.isEmpty) throw VintedException('No searches enabled in Settings.');
      for (final s in searches) {
        for (var p = 1; p <= settings.pagesPerSearch; p++) {
          if (_cancelled) throw _Cancelled();
          say('Vinted: ${s.format} "${s.term}" page $p…');
          final items = await vinted.searchPage(
            term: s.term,
            formatLabel: s.format,
            page: p,
            includeVeryGood: settings.includeVeryGood,
          );
          pagesRead++;
          listingsRead += items.length;
          for (final it in items) {
            all.putIfAbsent(it.id, () => it);
          }
          say('  ${items.length} listings (${all.length} unique so far)');
          if (items.isEmpty) break;
        }
      }
      if (all.isEmpty) throw VintedException('Vinted returned no listings.');

      // Pre-filter: cheap items and (optionally) already-reported ones.
      final seenIds = seen.map((e) => e.id).toSet();
      final pool = all.values.where((l) {
        final landed = l.inclPrice + settings.shippingAssumption;
        if (landed < settings.minLandedCost) return false;
        if (settings.skipSeen && seenIds.contains(l.id)) return false;
        return true;
      }).toList();
      say('${pool.length} listings pass the price filter; asking Claude to pick candidates…');

      // ------------------------------------------------------- Stage 1
      final picks = await claude.pickCandidates(
        listings: pool,
        maxCandidates: settings.maxCandidates,
        minLanded: settings.minLandedCost,
        shippingAssumption: settings.shippingAssumption,
        extraRules: settings.extraRules,
      );
      final candidates = <Candidate>[];
      for (final p in picks) {
        final id = (p['id'] as num?)?.toInt() ?? int.tryParse('${p['id']}');
        if (id == null || !all.containsKey(id)) continue;
        candidates.add(Candidate(
          listing: all[id]!,
          why: (p['why'] ?? '').toString(),
          ebayQuery: (p['ebay_query'] ?? all[id]!.title).toString(),
          compCondition:
              (p['comp_condition'] ?? 'sealed').toString().toLowerCase() == 'used'
                  ? 'used'
                  : 'sealed',
          seenBefore: seenIds.contains(id),
        ));
        if (candidates.length >= settings.maxCandidates) break;
      }
      say('${candidates.length} candidates to comp.');

      // ------------------------------------------------------- Stage 2
      for (final c in candidates) {
        if (_cancelled) throw _Cancelled();
        final l = c.listing;
        say('Comping: ${l.title}');
        VintedItemDetail? detail;
        try {
          detail = await vinted.itemDetail(l.id);
        } catch (_) {}
        final shipping =
            detail?.freeShipping == true ? 0.0 : settings.shippingAssumption;
        final landed = l.inclPrice + shipping;
        final soldUrl =
            EbayClient.soldSearchUri(c.ebayQuery, compCondition: c.compCondition)
                .toString();
        try {
          final text = await ebay.soldSearchText(c.ebayQuery,
              compCondition: c.compCondition);
          final j = await claude.readComps(
            c: c,
            landedCost: landed,
            ebayText: text,
            detail: detail,
            extraRules: settings.extraRules,
          );
          final comps = ((j['comps'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(Comp.fromJson)
              .toList();
          final level = (j['current_level'] is num)
              ? (j['current_level'] as num).toDouble()
              : double.tryParse('${j['current_level']}');
          var verdict = _parseVerdict((j['verdict'] ?? '').toString());
          // Re-apply the hard rule in code so the model can't drift.
          if (level != null) {
            final clears = level >= 2 * landed && level >= landed + 15;
            if (clears && verdict == Verdict.no) verdict = Verdict.borderline;
            if (!clears && verdict == Verdict.deal) verdict = Verdict.borderline;
          } else if (verdict == Verdict.deal) {
            verdict = Verdict.borderline;
          }
          final caveats = ((j['caveats'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList();
          if (detail != null && detail.sellerFeedbackCount < 5) {
            caveats.add('Vinted seller has only ${detail.sellerFeedbackCount} reviews');
          }
          if (c.seenBefore) caveats.add('Reported in an earlier scan');
          results.add(CandidateResult(
            candidate: c,
            landedCost: landed,
            shippingAssumed: shipping,
            comps: comps,
            trend: (j['trend'] ?? '').toString(),
            currentLevel: level,
            verdict: verdict,
            reason: (j['reason'] ?? '').toString(),
            caveats: caveats,
            ebaySoldUrl: soldUrl,
            detail: detail,
          ));
          say('  → ${verdict.name.toUpperCase()}'
              '${level == null ? '' : ' (current level \$${level.toStringAsFixed(2)} vs landed \$${landed.toStringAsFixed(2)})'}');
        } on EbayException catch (e) {
          say('  eBay problem: $e');
          results.add(_errorResult(c, landed, shipping, soldUrl, detail, e.toString()));
          if (e.toString().contains('bot-check')) {
            say('Stopping comps: eBay is bot-checking. Results so far are kept.');
            break;
          }
        } catch (e) {
          say('  Comp failed: $e');
          results.add(_errorResult(c, landed, shipping, soldUrl, detail, e.toString()));
        }
      }
      say('Done. ${results.where((r) => r.verdict == Verdict.deal).length} deal(s), '
          '${results.where((r) => r.verdict == Verdict.borderline).length} borderline.');
    } on _Cancelled {
      fatal = 'Scan cancelled.';
      say(fatal);
    } catch (e) {
      fatal = e.toString();
      say('Scan stopped: $fatal');
    } finally {
      session.close();
    }

    return ScanResult(
      startedAt: started,
      finishedAt: DateTime.now(),
      listingsRead: listingsRead,
      pagesRead: pagesRead,
      results: results,
      log: log,
      fatalError: fatal,
    );
  }

  static CandidateResult _errorResult(Candidate c, double landed, double shipping,
          String soldUrl, VintedItemDetail? detail, String err) =>
      CandidateResult(
        candidate: c,
        landedCost: landed,
        shippingAssumed: shipping,
        comps: const [],
        trend: '',
        currentLevel: null,
        verdict: Verdict.error,
        reason: err,
        caveats: const [],
        ebaySoldUrl: soldUrl,
        detail: detail,
        error: err,
      );

  static Verdict _parseVerdict(String v) {
    switch (v.toLowerCase().trim()) {
      case 'deal':
        return Verdict.deal;
      case 'borderline':
        return Verdict.borderline;
      default:
        return Verdict.no;
    }
  }
}

class _Cancelled implements Exception {}
