import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One stored comp result: what a title (in one condition) is selling for on
/// eBay right now, from a real Sold Items search.
class PriceEntry {
  final String key;
  final String name;
  final String format;
  final String query;
  final String condition; // sealed | used
  final double? level; // current buyer-total selling level
  final String confidence; // good | thin | none
  final String trend;
  final int saleCount;
  final DateTime checked;

  PriceEntry({
    required this.key,
    required this.name,
    required this.format,
    required this.query,
    required this.condition,
    required this.level,
    required this.confidence,
    required this.trend,
    required this.saleCount,
    required this.checked,
  });

  int get ageDays => DateTime.now().difference(checked).inDays;

  Map<String, dynamic> toJson() => {
        'k': key,
        'n': name,
        'f': format,
        'q': query,
        'c': condition,
        'l': level,
        'cf': confidence,
        't': trend,
        's': saleCount,
        'd': checked.toIso8601String(),
      };

  factory PriceEntry.fromJson(Map<String, dynamic> j) => PriceEntry(
        key: (j['k'] ?? '').toString(),
        name: (j['n'] ?? '').toString(),
        format: (j['f'] ?? '').toString(),
        query: (j['q'] ?? '').toString(),
        condition: (j['c'] ?? 'used').toString(),
        level: (j['l'] as num?)?.toDouble(),
        confidence: (j['cf'] ?? 'none').toString(),
        trend: (j['t'] ?? '').toString(),
        saleCount: (j['s'] as num?)?.toInt() ?? 0,
        checked: DateTime.tryParse((j['d'] ?? '').toString()) ?? DateTime(2000),
      );
}

/// Local price database built up from every comp the shelf check runs.
/// Lookups are instant; entries older than [maxAgeDays] are re-comped so a
/// falling price is not missed.
class PriceDb {
  static const _k = 'price_db_v1';
  static const maxAgeDays = 21;
  final Map<String, PriceEntry> _m = {};
  bool _loaded = false;

  int get length => _m.length;

  static const _stop = {'the', 'a', 'an', 'and', 'of', '&'};

  /// Same title + format + condition gives the same key however the words
  /// were ordered or punctuated.
  static String keyFor(String query, String condition) {
    final words = query
        .toLowerCase()
        .replaceAll(RegExp(r'blu[\s-]?ray'), 'bluray')
        .replaceAll(RegExp(r"[^a-z0-9 ]"), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !_stop.contains(w))
        .toSet()
        .toList()
      ..sort();
    return '${words.join(' ')}|$condition';
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_k);
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          final p = PriceEntry.fromJson(e as Map<String, dynamic>);
          _m[p.key] = p;
        }
      } catch (_) {}
    }
    _loaded = true;
  }

  /// A fresh entry for this title, or null if it has to be comped.
  PriceEntry? fresh(String query, String condition) {
    final e = _m[keyFor(query, condition)];
    if (e == null || e.ageDays > maxAgeDays) return null;
    return e;
  }

  Future<void> put(PriceEntry e) async {
    _m[e.key] = e;
    await _save();
  }

  Future<void> clear() async {
    _m.clear();
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _m.values.toList()..sort((a, b) => b.checked.compareTo(a.checked));
    await prefs.setString(_k, jsonEncode(list.take(5000).map((e) => e.toJson()).toList()));
  }
}
