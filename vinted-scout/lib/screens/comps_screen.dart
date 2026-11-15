import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../comps/comp_engine.dart';
import '../settings.dart';

/// Price check for one eBay or Vinted listing: opened from the share sheet
/// ("Mojo Comps") or by pasting a link / item number.
class CompsScreen extends StatefulWidget {
  final AppSettings settings;
  final String? initialText;
  const CompsScreen({super.key, required this.settings, this.initialText});

  @override
  State<CompsScreen> createState() => _CompsScreenState();
}

class _CompsScreenState extends State<CompsScreen> {
  final _input = TextEditingController();
  CompEngine? _engine;
  CompsReport? _report;
  String _status = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = widget.initialText;
    if (t != null && t.trim().isNotEmpty) {
      _input.text = t.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  @override
  void dispose() {
    _engine?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    if (d?.text != null) setState(() => _input.text = d!.text!.trim());
  }

  Future<void> _check() async {
    if (_engine != null) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (!widget.settings.hasKey) {
      setState(() => _error = 'Add your Anthropic API key in Settings first.');
      return;
    }
    FocusScope.of(context).unfocus();
    final engine = CompEngine(
      settings: widget.settings,
      onProgress: (m) {
        if (mounted) setState(() => _status = m);
      },
      onUpdate: () {
        if (mounted) setState(() {});
      },
    );
    setState(() {
      _engine = engine;
      _report = null;
      _error = null;
      _status = 'Starting…';
    });
    try {
      final r = await engine.run(text);
      if (!mounted) return;
      setState(() => _report = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _engine = null);
    }
  }

  String _m(double? v) => v == null ? '—' : '\$${v.toStringAsFixed(2)}';

  Future<void> _open(String url) async {
    final u = Uri.tryParse(url);
    if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  String _asText(CompsReport r) {
    final b = StringBuffer();
    b.writeln('${r.verdictText}: ${r.title}');
    b.writeln('${r.listing.sourceName} ${r.listing.url}');
    b.writeln('Cost: ${_m(r.price)} + ${_m(r.shipping)} shipping'
        '${r.shippingAssumed ? ' (assumed)' : ''} = ${_m(r.cost)}');
    if (r.perDisc != null && r.discCount > 1) {
      b.writeln('Per item landed: ${_m(r.perDisc)} (${r.discCount} items)');
    }
    for (final f in r.flags) {
      b.writeln('${f.stop ? 'STOP' : 'Warn'}: ${f.text}');
    }
    for (final i in r.items) {
      b.writeln('- ${i.name} [${i.format}${i.edition.isEmpty ? '' : ', ${i.edition}'}]: '
          '${_m(i.level)} (${i.confidence})${i.trend.isEmpty ? '' : ' — ${i.trend}'}');
    }
    if (r.valued.isNotEmpty) {
      b.writeln('Total current level ${_m(r.totalLevel)} · est. net after fees/label ${_m(r.totalNet)}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final running = _engine != null;
    final r = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mojo Comps'),
        actions: [
          if (r != null)
            IconButton(
              tooltip: 'Copy report',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _asText(r)));
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Report copied')));
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          TextField(
            controller: _input,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'eBay / Vinted link or eBay item number',
              helperText: 'Tip: in the eBay or Vinted app tap Share → Mojo Comps',
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste),
                onPressed: running ? null : _paste,
              ),
            ),
            onSubmitted: (_) => _check(),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: running ? null : _check,
                icon: running
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.price_check),
                label: Text(running ? 'Checking…' : 'Check prices'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
            if (running) ...[
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => _engine?.cancel(), child: const Text('Stop')),
            ],
          ]),
          if (_status.isNotEmpty && running)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status, style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(_error!),
              ),
            ),
          if (r != null) ..._reportView(context, r),
        ],
      ),
    );
  }

  Color _verdictColor(CompsVerdict v) {
    switch (v) {
      case CompsVerdict.pass:
        return Colors.red;
      case CompsVerdict.good:
        return Colors.green;
      case CompsVerdict.thin:
        return Colors.orange;
      case CompsVerdict.no:
      case CompsVerdict.noComps:
        return Colors.grey;
    }
  }

  List<Widget> _reportView(BuildContext context, CompsReport r) {
    final tt = Theme.of(context).textTheme;
    final done = _engine == null;
    return [
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (done)
                Text(r.verdictText,
                    style: tt.titleLarge?.copyWith(
                        color: _verdictColor(r.verdict), fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(r.title.isEmpty ? r.listing.url : r.title, style: tt.titleSmall),
              if (r.summary.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text(r.summary)),
              const SizedBox(height: 8),
              Text('Cost: ${_m(r.price)} + ${_m(r.shipping)} shipping'
                  '${r.shippingAssumed ? ' (assumed)' : ''} = ${_m(r.cost)}'),
              if (r.auction && r.auctionNote.isNotEmpty) Text('Auction: ${r.auctionNote}'),
              if (r.perDisc != null && r.discCount > 1)
                Text('Per item landed: ${_m(r.perDisc)} across ${r.discCount} items '
                    '(lot target: under ${_m(SellCosts.lotTargetPerDisc)})'),
              if (r.valued.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('Current selling level, all comped items: ${_m(r.totalLevel)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('Est. net if each sold singly (after ~13.6% + \$0.40 fees and '
                    '\$4.39 label): ${_m(r.totalNet)}',
                    style: tt.bodySmall),
                if (r.valued.length < r.items.length)
                  Text('${r.items.length - r.valued.length} item(s) had no usable comps and count as \$0.',
                      style: tt.bodySmall),
              ],
              if (r.unidentified > 0)
                Text('${r.unidentified} item(s) in the lot are not named and were not comped.',
                    style: tt.bodySmall),
              if (r.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Error: ${r.error}', style: const TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () => _open(r.listing.url),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text('Open on ${r.listing.sourceName}'),
              ),
            ],
          ),
        ),
      ),
      for (final f in r.flags)
        Card(
          color: f.stop ? Colors.red.withValues(alpha: 0.12) : Colors.orange.withValues(alpha: 0.10),
          child: ListTile(
            leading: Icon(f.stop ? Icons.block : Icons.warning_amber,
                color: f.stop ? Colors.red : Colors.orange),
            title: Text(f.text),
          ),
        ),
      if (r.items.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text('Per item (${r.items.length})', style: tt.titleMedium),
        ),
      for (final i in r.items) _itemTile(context, i, r.hasStop),
    ];
  }

  Widget _itemTile(BuildContext context, ItemComp i, bool skipped) {
    final tt = Theme.of(context).textTheme;
    final sub = <String>[
      [i.format, if (i.edition.isNotEmpty) i.edition, i.compCondition].join(' · '),
      if (skipped) 'Not comped (red flag)',
      if (!skipped && i.confidence == 'pending') 'Waiting…',
      if (i.trend.isNotEmpty) i.trend,
      if (i.note.isNotEmpty) i.note,
    ];
    final levelText = skipped
        ? ''
        : i.confidence == 'pending'
            ? '…'
            : i.level == null
                ? 'no comps'
                : _m(i.level);
    return Card(
      child: ExpansionTile(
        title: Text(i.name),
        subtitle: Text(sub.join('\n'), style: tt.bodySmall),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(levelText, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (i.level != null)
              Text(i.confidence, style: tt.bodySmall),
          ],
        ),
        children: [
          for (final s in i.sales)
            ListTile(
              dense: true,
              title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${s.date} · ${s.condition} · ${_m(s.price)} + ${_m(s.shipping)}'),
              trailing: Text(_m(s.total)),
            ),
          if (!skipped)
            TextButton.icon(
              onPressed: () => _open(i.soldUrl),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open eBay sold search'),
            ),
        ],
      ),
    );
  }
}
