import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class SearchSpec {
  final String format; // label shown in results
  final String term; // Vinted search_text
  final bool enabled;
  const SearchSpec(this.format, this.term, {this.enabled = true});

  SearchSpec copyWith({bool? enabled}) =>
      SearchSpec(format, term, enabled: enabled ?? this.enabled);

  Map<String, dynamic> toJson() =>
      {'format': format, 'term': term, 'enabled': enabled};
  factory SearchSpec.fromJson(Map<String, dynamic> j) => SearchSpec(
        (j['format'] ?? '').toString(),
        (j['term'] ?? '').toString(),
        enabled: j['enabled'] != false,
      );
}

class AppSettings {
  String apiKey;
  String model;
  int pagesPerSearch;
  int maxCandidates;
  double shippingAssumption; // added to incl. price when listing isn't free-ship
  double minLandedCost; // skip anything cheaper than this
  bool includeVeryGood; // condition "Very good" (used) in addition to NWT/NWOT
  bool skipSeen; // skip items already reported in an earlier scan
  List<SearchSpec> searches;
  String extraRules; // free-text additions to the judgment prompt

  AppSettings({
    this.apiKey = '',
    this.model = 'claude-sonnet-5-5',
    this.pagesPerSearch = 2,
    this.maxCandidates = 8,
    this.shippingAssumption = 5.0,
    this.minLandedCost = 8.0,
    this.includeVeryGood = true,
    this.skipSeen = true,
    List<SearchSpec>? searches,
    this.extraRules = '',
  }) : searches = searches ?? defaultSearches();

  static List<SearchSpec> defaultSearches() => const [
        SearchSpec('Blu-ray', 'blu-ray'),
        SearchSpec('CD', 'cd'),
        SearchSpec('Cassette', 'cassette tape'),
      ];

  bool get hasKey => apiKey.trim().isNotEmpty;
}

class SettingsStore {
  static const _secure = FlutterSecureStorage();
  static const _kKey = 'anthropic_api_key';
  static const _kSettings = 'settings_json';
  static const _kSeen = 'seen_items_json';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = AppSettings();
    final raw = prefs.getString(_kSettings);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        s.model = (j['model'] ?? s.model).toString();
        s.pagesPerSearch = (j['pages'] as num?)?.toInt() ?? s.pagesPerSearch;
        s.maxCandidates = (j['maxCandidates'] as num?)?.toInt() ?? s.maxCandidates;
        s.shippingAssumption =
            (j['shipping'] as num?)?.toDouble() ?? s.shippingAssumption;
        s.minLandedCost = (j['minLanded'] as num?)?.toDouble() ?? s.minLandedCost;
        s.includeVeryGood = j['includeVeryGood'] != false;
        s.skipSeen = j['skipSeen'] != false;
        s.extraRules = (j['extraRules'] ?? '').toString();
        final list = j['searches'];
        if (list is List && list.isNotEmpty) {
          s.searches = list
              .map((e) => SearchSpec.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }
    try {
      s.apiKey = await _secure.read(key: _kKey) ?? '';
    } catch (_) {
      // Secure storage can fail on some devices; fall back to prefs.
      s.apiKey = prefs.getString(_kKey) ?? '';
    }
    return s;
  }

  Future<void> save(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kSettings,
      jsonEncode({
        'model': s.model,
        'pages': s.pagesPerSearch,
        'maxCandidates': s.maxCandidates,
        'shipping': s.shippingAssumption,
        'minLanded': s.minLandedCost,
        'includeVeryGood': s.includeVeryGood,
        'skipSeen': s.skipSeen,
        'extraRules': s.extraRules,
        'searches': s.searches.map((e) => e.toJson()).toList(),
      }),
    );
    try {
      await _secure.write(key: _kKey, value: s.apiKey.trim());
      await prefs.remove(_kKey);
    } catch (_) {
      await prefs.setString(_kKey, s.apiKey.trim());
    }
  }

  Future<List<SeenItem>> loadSeen() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSeen);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SeenItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSeen(List<SeenItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    // Keep the newest 500.
    items.sort((a, b) => b.when.compareTo(a.when));
    final trimmed = items.take(500).toList();
    await prefs.setString(
        _kSeen, jsonEncode(trimmed.map((e) => e.toJson()).toList()));
  }

  Future<void> clearSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSeen);
  }
}
