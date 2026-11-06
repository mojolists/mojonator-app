/// Data models for Vinted Scout.
library;

class VintedListing {
  final int id;
  final String title;
  final String condition; // "New with tags", "New without tags", "Very good", ...
  final double price; // seller price
  final double inclPrice; // buyer total incl. Vinted fee
  final String url;
  final String? photoUrl;
  final String format; // which search it came from: Blu-ray / CD / Cassette / custom
  final String searchTerm;

  VintedListing({
    required this.id,
    required this.title,
    required this.condition,
    required this.price,
    required this.inclPrice,
    required this.url,
    required this.format,
    required this.searchTerm,
    this.photoUrl,
  });

  String get compactLine =>
      '$id | $format | $condition | \$${inclPrice.toStringAsFixed(2)} incl | $title';
}

class VintedItemDetail {
  final String description;
  final String sellerLogin;
  final int sellerFeedbackCount;
  final bool? freeShipping;
  final String? shippingNote;

  VintedItemDetail({
    required this.description,
    required this.sellerLogin,
    required this.sellerFeedbackCount,
    this.freeShipping,
    this.shippingNote,
  });
}

class Candidate {
  final VintedListing listing;
  final String why;
  final String ebayQuery;
  final String compCondition; // "sealed" or "used"
  final bool seenBefore;

  Candidate({
    required this.listing,
    required this.why,
    required this.ebayQuery,
    required this.compCondition,
    this.seenBefore = false,
  });
}

class Comp {
  final String date;
  final String title;
  final double? price;
  final double? shipping;
  final double? total;
  final String condition;
  final bool sameEdition;

  Comp({
    required this.date,
    required this.title,
    required this.price,
    required this.shipping,
    required this.total,
    required this.condition,
    required this.sameEdition,
  });

  factory Comp.fromJson(Map<String, dynamic> j) => Comp(
        date: (j['date'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        price: _num(j['price']),
        shipping: _num(j['shipping']),
        total: _num(j['total']),
        condition: (j['condition'] ?? '').toString(),
        sameEdition: j['same_edition'] == true,
      );
}

double? _num(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  final s = v.toString().replaceAll(RegExp(r'[^0-9.\-]'), '');
  return double.tryParse(s);
}

enum Verdict { deal, borderline, no, error }

class CandidateResult {
  final Candidate candidate;
  final double landedCost;
  final double shippingAssumed;
  final List<Comp> comps;
  final String trend;
  final double? currentLevel;
  final Verdict verdict;
  final String reason;
  final List<String> caveats;
  final String ebaySoldUrl;
  final VintedItemDetail? detail;
  final String? error;

  CandidateResult({
    required this.candidate,
    required this.landedCost,
    required this.shippingAssumed,
    required this.comps,
    required this.trend,
    required this.currentLevel,
    required this.verdict,
    required this.reason,
    required this.caveats,
    required this.ebaySoldUrl,
    this.detail,
    this.error,
  });

  VintedListing get listing => candidate.listing;
}

class ScanResult {
  final DateTime startedAt;
  final DateTime finishedAt;
  final int listingsRead;
  final int pagesRead;
  final List<CandidateResult> results;
  final List<String> log;
  final String? fatalError;

  ScanResult({
    required this.startedAt,
    required this.finishedAt,
    required this.listingsRead,
    required this.pagesRead,
    required this.results,
    required this.log,
    this.fatalError,
  });

  List<CandidateResult> get deals =>
      results.where((r) => r.verdict == Verdict.deal).toList();
  List<CandidateResult> get borderline =>
      results.where((r) => r.verdict == Verdict.borderline).toList();
  List<CandidateResult> get rejected =>
      results.where((r) => r.verdict == Verdict.no).toList();
  List<CandidateResult> get errors =>
      results.where((r) => r.verdict == Verdict.error).toList();
}

/// One line in the "already reported" log.
class SeenItem {
  final int id;
  final String title;
  final DateTime when;
  final String verdict;
  final double landedCost;
  final double? currentLevel;
  final String url;

  SeenItem({
    required this.id,
    required this.title,
    required this.when,
    required this.verdict,
    required this.landedCost,
    required this.currentLevel,
    required this.url,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'when': when.toIso8601String(),
        'verdict': verdict,
        'landed': landedCost,
        'level': currentLevel,
        'url': url,
      };

  factory SeenItem.fromJson(Map<String, dynamic> j) => SeenItem(
        id: (j['id'] as num).toInt(),
        title: (j['title'] ?? '').toString(),
        when: DateTime.tryParse((j['when'] ?? '').toString()) ?? DateTime.now(),
        verdict: (j['verdict'] ?? '').toString(),
        landedCost: _num(j['landed']) ?? 0,
        currentLevel: _num(j['level']),
        url: (j['url'] ?? '').toString(),
      );
}
