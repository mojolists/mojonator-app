import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';

class ResultCard extends StatelessWidget {
  final CandidateResult result;
  final bool compact;
  const ResultCard({super.key, required this.result, this.compact = false});

  Color _verdictColor(BuildContext context) {
    switch (result.verdict) {
      case Verdict.deal:
        return Colors.green;
      case Verdict.borderline:
        return Colors.orange;
      case Verdict.no:
        return Theme.of(context).colorScheme.outline;
      case Verdict.error:
        return Colors.red;
    }
  }

  String _money(double? v) => v == null ? '—' : '\$${v.toStringAsFixed(2)}';

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _asText() {
    final r = result;
    final l = r.listing;
    final b = StringBuffer();
    b.writeln('${r.verdict.name.toUpperCase()}: ${l.title}');
    b.writeln('Vinted: ${_money(l.price)} / ${_money(l.inclPrice)} incl · '
        'shipping ${_money(r.shippingAssumed)} · landed ${_money(r.landedCost)} · ${l.condition}');
    if (r.currentLevel != null) {
      b.writeln('eBay current level: ${_money(r.currentLevel)} — ${r.trend}');
    }
    for (final c in r.comps) {
      b.writeln('  ${c.date} ${_money(c.total)} (${_money(c.price)} + ${_money(c.shipping)}) '
          '${c.condition}${c.sameEdition ? '' : ' [other edition]'} — ${c.title}');
    }
    if (r.reason.isNotEmpty) b.writeln(r.reason);
    for (final c in r.caveats) {
      b.writeln('Caveat: $c');
    }
    b.writeln(l.url);
    b.writeln(r.ebaySoldUrl);
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    final l = r.listing;
    final color = _verdictColor(context);
    final theme = Theme.of(context);
    final detail = r.detail;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.6), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (l.photoUrl != null && !compact)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        l.photoUrl!,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, st) =>
                            const SizedBox(width: 72, height: 72),
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              r.verdict.name.toUpperCase(),
                              style: TextStyle(
                                  color: color,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${l.format} · ${l.condition}',
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(l.title,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _kv('Vinted', '${_money(l.price)} / ${_money(l.inclPrice)} incl'),
                _kv('Shipping', _money(r.shippingAssumed)),
                _kv('Landed', _money(r.landedCost), bold: true),
                if (r.currentLevel != null)
                  _kv('eBay now', _money(r.currentLevel), bold: true),
                if (r.currentLevel != null)
                  _kv('Spread', _money(r.currentLevel! - r.landedCost)),
              ],
            ),
            if (r.trend.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Trend: ${r.trend}', style: theme.textTheme.bodyMedium),
            ],
            if (r.reason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(r.reason, style: theme.textTheme.bodyMedium),
            ],
            if (!compact && r.comps.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('eBay sold comps (newest first, buyer total)',
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: 2),
              ...r.comps.map((c) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      '${c.date.padRight(13)} ${_money(c.total).padLeft(9)}  '
                      '${c.condition}${c.sameEdition ? '' : ' · other edition'} — ${c.title}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: c.sameEdition
                            ? null
                            : theme.colorScheme.outline,
                      ),
                    ),
                  )),
            ],
            if (detail != null && !compact) ...[
              const SizedBox(height: 6),
              Text(
                'Seller ${detail.sellerLogin} · ${detail.sellerFeedbackCount} reviews'
                '${detail.freeShipping == true ? ' · free shipping' : ''}',
                style: theme.textTheme.bodySmall,
              ),
              if (detail.description.trim().isNotEmpty)
                Text(
                  detail.description.trim(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
            ],
            if (r.caveats.isNotEmpty) ...[
              const SizedBox(height: 6),
              ...r.caveats.map((c) => Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 16, color: Colors.orange),
                      const SizedBox(width: 6),
                      Expanded(child: Text(c, style: theme.textTheme.bodySmall)),
                    ],
                  )),
            ],
            if (r.candidate.why.isNotEmpty && compact)
              Text('Picked because: ${r.candidate.why}',
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _open(l.url),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open on Vinted'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _open(r.ebaySoldUrl),
                  icon: const Icon(Icons.sell_outlined, size: 16),
                  label: const Text('eBay sold'),
                ),
                IconButton(
                  tooltip: 'Copy as text',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _asText()));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied')));
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v, {bool bold = false}) => Builder(
        builder: (context) {
          final cs = Theme.of(context).colorScheme;
          return RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 13, color: cs.outline),
              children: [
                TextSpan(text: '$k '),
                TextSpan(
                  text: v,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          );
        },
      );
}
