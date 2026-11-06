import 'dart:convert';

import 'models.dart';
import 'net.dart';

class VintedException implements Exception {
  final String message;
  VintedException(this.message);
  @override
  String toString() => message;
}

/// Reads the public Vinted catalog the same way the website does:
/// a first hit on the homepage sets the anonymous session cookies, then the
/// JSON catalog endpoint is called with those cookies.
class VintedClient {
  static const host = 'https://www.vinted.com';
  final BrowserSession session;
  bool _primed = false;

  VintedClient(this.session);

  // Vinted status_ids: 6 = New with tags, 1 = New without tags, 2 = Very good,
  // 3 = Good, 4 = Satisfactory.
  static List<int> statusIds({required bool includeVeryGood}) =>
      includeVeryGood ? const [6, 1, 2] : const [6, 1];

  Future<void> _prime() async {
    if (_primed) return;
    final r = await session.get(Uri.parse('$host/'));
    if (r.status == 403) {
      throw VintedException(
          'Vinted refused the first request (HTTP 403, bot check). Wait a few minutes and try again, or switch networks.');
    }
    _primed = true;
  }

  Map<String, String> get _jsonHeaders => const {
        'Accept': 'application/json, text/plain, */*',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': '$host/catalog',
      };

  /// One page of search results.
  Future<List<VintedListing>> searchPage({
    required String term,
    required String formatLabel,
    required int page,
    required bool includeVeryGood,
  }) async {
    await _prime();
    final qp = <String, List<String>>{
      'page': ['$page'],
      'per_page': ['96'],
      'search_text': [term],
      'order': ['newest_first'],
      'status_ids[]':
          statusIds(includeVeryGood: includeVeryGood).map((e) => '$e').toList(),
    };
    final uri = Uri.parse('$host/api/v2/catalog/items')
        .replace(queryParameters: qp);
    var r = await session.get(uri, headers: _jsonHeaders);
    if (r.status == 401 || r.status == 403) {
      // Session may have gone stale; re-prime once.
      _primed = false;
      await _prime();
      r = await session.get(uri, headers: _jsonHeaders);
    }
    if (!r.ok) {
      throw VintedException(
          'Vinted catalog request failed (HTTP ${r.status}) for "$term" page $page.');
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw VintedException(
          'Vinted returned something that is not JSON for "$term" page $page (probably a bot-check page).');
    }
    final items = (j['items'] as List?) ?? const [];
    final out = <VintedListing>[];
    for (final it in items) {
      if (it is! Map<String, dynamic>) continue;
      final id = (it['id'] as num?)?.toInt();
      if (id == null) continue;
      final title = (it['title'] ?? '').toString().trim();
      final price = _amount(it['price']);
      final incl = _amount(it['total_item_price']) ?? price;
      if (price == null || incl == null) continue;
      final status = (it['status'] ?? '').toString();
      var url = (it['url'] ?? '').toString();
      if (url.isEmpty) url = '$host/items/$id';
      final photo = it['photo'];
      final photoUrl = photo is Map ? (photo['url']?.toString()) : null;
      out.add(VintedListing(
        id: id,
        title: title,
        condition: status,
        price: price,
        inclPrice: incl,
        url: url,
        photoUrl: photoUrl,
        format: formatLabel,
        searchTerm: term,
      ));
    }
    return out;
  }

  /// Full item details for a candidate: description, seller feedback, and a
  /// best-effort read on free shipping.
  Future<VintedItemDetail?> itemDetail(int id) async {
    await _prime();
    final uri = Uri.parse('$host/api/v2/items/$id');
    final r = await session.get(uri, headers: _jsonHeaders);
    if (!r.ok) return null;
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final item = (j['item'] as Map<String, dynamic>?) ?? j;
      final user = item['user'];
      final login = user is Map ? (user['login'] ?? '').toString() : '';
      final fb = user is Map
          ? ((user['feedback_count'] as num?)?.toInt() ??
              (user['positive_feedback_count'] as num?)?.toInt() ??
              0)
          : 0;
      final desc = (item['description'] ?? '').toString();
      bool? free;
      String? note;
      final raw = r.body;
      if (RegExp(r'"free_shipping"\s*:\s*true').hasMatch(raw)) {
        free = true;
      } else if (RegExp(r'"free_shipping"\s*:\s*false').hasMatch(raw)) {
        free = false;
      }
      final lower = desc.toLowerCase();
      if (free == null && lower.contains('free shipping')) {
        free = true;
        note = 'Description mentions free shipping';
      }
      return VintedItemDetail(
        description: desc,
        sellerLogin: login,
        sellerFeedbackCount: fb,
        freeShipping: free,
        shippingNote: note,
      );
    } catch (_) {
      return null;
    }
  }

  static double? _amount(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    if (v is Map) {
      final a = v['amount'];
      if (a is num) return a.toDouble();
      if (a is String) return double.tryParse(a);
    }
    return null;
  }
}
