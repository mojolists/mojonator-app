import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../settings.dart';
import '../shelf/price_db.dart';
import '../shelf/shelf_engine.dart';

/// Shelf check: photograph a shelf, box or lot and get a buy / skip list.
class ShelfScreen extends StatefulWidget {
  final AppSettings settings;
  const ShelfScreen({super.key, required this.settings});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  final _db = PriceDb();
  final _picker = ImagePicker();
  final _priceCtl = TextEditingController();
  double _price = 1.00;
  double _packaging = 1.00;
  Uint8List? _photo;
  ShelfEngine? _engine;
  ShelfReport? _report;
  String _status = '';
  String? _error;
  bool _canCamera = false;
  bool _showSkips = false;

  static const _kPrice = 'shelf_price_each';
  static const _kPack = 'shelf_packaging';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    await _db.load();
    bool cam = false;
    try {
      cam = _picker.supportsImageSource(ImageSource.camera);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _price = prefs.getDouble(_kPrice) ?? 1.00;
      _packaging = prefs.getDouble(_kPack) ?? 1.00;
      _priceCtl.text = _price.toStringAsFixed(2);
      _canCamera = cam;
    });
  }

  @override
  void dispose() {
    _engine?.cancel();
    _priceCtl.dispose();
    super.dispose();
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kPrice, _price);
    await prefs.setDouble(_kPack, _packaging);
  }

  Future<void> _pick(ImageSource src) async {
    if (_engine != null) return;
    if (!widget.settings.hasKey) {
      setState(() => _error = 'Add your Anthropic API key in Settings first.');
      return;
    }
    XFile? f;
    try {
      f = await _picker.pickImage(source: src, maxWidth: 3200, maxHeight: 3200, imageQuality: 92);
    } catch (e) {
      setState(() => _error = 'Could not get the photo: $e');
      return;
    }
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    setState(() => _photo = bytes);
    await _run(bytes);
  }

  Future<void> _run(Uint8List bytes) async {
    final engine = ShelfEngine(
      settings: widget.settings,
      db: _db,
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
      final r = await engine.run(bytes);
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

  int _order(ShelfVerdict v) => const {
        ShelfVerdict.buy: 0,
        ShelfVerdict.maybe: 1,
        ShelfVerdict.pending: 2,
        ShelfVerdict.error: 3,
        ShelfVerdict.skip: 4,
        ShelfVerdict.stop: 5,
      }[v]!;

  List<ShelfItem> _sorted(ShelfReport r) {
    final list = [...r.items];
    list.sort((a, b) {
      final va = a.verdict(_price, _packaging), vb = b.verdict(_price, _packaging);
      final c = _order(va).compareTo(_order(vb));
      if (c != 0) return c;
      return (b.profit(_price, _packaging) ?? -999).compareTo(a.profit(_price, _packaging) ?? -999);
    });
    return list;
  }

  String _asText(ShelfReport r) {
    final b = StringBuffer('Shelf check — ${r.summary}\n');
    b.writeln('Price each ${_m(_price)} + tax, packaging ${_m(_packaging)}, target \$2 profit');
    for (final it in _sorted(r)) {
      final v = it.verdict(_price, _packaging);
      b.writeln('${_label(v)}: ${it.name} [${it.format}${it.edition.isEmpty ? '' : ', ${it.edition}'}] '
          'sells ~${_m(it.level)}, profit ${_m(it.profit(_price, _packaging))}'
          '${it.readConfidence == 'unsure' ? ' (title unsure)' : ''}');
    }
    if (r.unreadable > 0) b.writeln('${r.unreadable} unreadable');
    return b.toString();
  }

  String _label(ShelfVerdict v) {
    switch (v) {
      case ShelfVerdict.buy:
        return 'BUY';
      case ShelfVerdict.maybe:
        return 'MAYBE';
      case ShelfVerdict.skip:
        return 'SKIP';
      case ShelfVerdict.stop:
        return 'STOP';
      case ShelfVerdict.pending:
        return '…';
      case ShelfVerdict.error:
        return 'ERROR';
    }
  }

  Color _color(ShelfVerdict v) {
    switch (v) {
      case ShelfVerdict.buy:
        return Colors.green;
      case ShelfVerdict.maybe:
        return Colors.orange;
      case ShelfVerdict.stop:
      case ShelfVerdict.error:
        return Colors.red;
      case ShelfVerdict.skip:
      case ShelfVerdict.pending:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _engine != null;
    final r = _report ?? _engine?.report;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shelf check'),
        actions: [
          if (_report != null)
            IconButton(
              tooltip: 'Copy list',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _asText(_report!)));
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('List copied')));
                }
              },
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'clear') {
                await _db.clear();
                if (mounted) setState(() {});
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'clear',
                child: Text('Clear price database (${_db.length} titles)'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _priceCtl,
                enabled: !running,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Price each',
                  prefixText: '\$',
                  helperText: 'TX tax added',
                ),
                onChanged: (v) {
                  final d = double.tryParse(v.trim());
                  if (d != null) {
                    setState(() => _price = d);
                    _savePrefs();
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Packaging', style: tt.bodySmall),
              SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 1.00, label: Text('\$1')),
                  ButtonSegment(value: 0.50, label: Text('\$0.50')),
                ],
                selected: {_packaging},
                onSelectionChanged: (s) {
                  setState(() => _packaging = s.first);
                  _savePrefs();
                },
              ),
            ]),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            if (_canCamera)
              Expanded(
                child: FilledButton.icon(
                  onPressed: running ? null : () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Take photo'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
            if (_canCamera) const SizedBox(width: 8),
            Expanded(
              child: _canCamera
                  ? OutlinedButton.icon(
                      onPressed: running ? null : () => _pick(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Choose photo'),
                    )
                  : FilledButton.icon(
                      onPressed: running ? null : () => _pick(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Choose photo'),
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
            ),
            if (running) ...[
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => _engine?.cancel(), child: const Text('Stop')),
            ],
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Tip: 20–30 spines per photo, straight on and in focus. '
              'Price database: ${_db.length} titles.',
              style: tt.bodySmall,
            ),
          ),
          if (_status.isNotEmpty && running)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(child: Text(_status, style: tt.bodySmall)),
              ]),
            ),
          if (_error != null) _errorCard(_error!),
          if (_photo != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(_photo!, height: 140, fit: BoxFit.cover, width: double.infinity),
              ),
            ),
          if (r != null) ..._reportView(context, r),
        ],
      ),
    );
  }

  Widget _errorCard(String text) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(padding: const EdgeInsets.all(12), child: SelectableText(text)),
      );

  List<Widget> _reportView(BuildContext context, ShelfReport r) {
    final tt = Theme.of(context).textTheme;
    final items = _sorted(r);
    final counts = <ShelfVerdict, int>{};
    for (final it in items) {
      final v = it.verdict(_price, _packaging);
      counts[v] = (counts[v] ?? 0) + 1;
    }
    final shown = _showSkips
        ? items
        : items.where((i) => i.verdict(_price, _packaging) != ShelfVerdict.skip).toList();
    final skips = counts[ShelfVerdict.skip] ?? 0;
    return [
      const SizedBox(height: 12),
      if (r.error != null) _errorCard(r.error!),
      if (r.summary.isNotEmpty || items.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (r.summary.isNotEmpty) Text(r.summary, style: tt.titleSmall),
              const SizedBox(height: 6),
              Text('Buy ${counts[ShelfVerdict.buy] ?? 0} · Maybe ${counts[ShelfVerdict.maybe] ?? 0} · '
                  'Skip $skips'
                  '${(counts[ShelfVerdict.stop] ?? 0) > 0 ? ' · Red flag ${counts[ShelfVerdict.stop]}' : ''}'
                  '${(counts[ShelfVerdict.pending] ?? 0) > 0 ? ' · Checking ${counts[ShelfVerdict.pending]}' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('BUY = at least \$2 profit with 3+ recent sales. Profit = sold buyer total − '
                  '13.6% + \$0.40 fees − \$4.39 label − packaging − price with tax.',
                  style: tt.bodySmall),
              if (r.unreadable > 0)
                Text('${r.unreadable} item(s) too blurry or small to read — take a closer photo of those.',
                    style: tt.bodySmall),
            ]),
          ),
        ),
      for (final it in shown) _tile(context, it),
      if (skips > 0)
        TextButton(
          onPressed: () => setState(() => _showSkips = !_showSkips),
          child: Text('${_showSkips ? 'Hide' : 'Show'} skips ($skips)'),
        ),
    ];
  }

  Widget _tile(BuildContext context, ShelfItem it) {
    final tt = Theme.of(context).textTheme;
    final v = it.verdict(_price, _packaging);
    final p = it.profit(_price, _packaging);
    final sub = <String>[
      [it.format, if (it.edition.isNotEmpty) it.edition, it.compCondition].join(' · '),
      if (it.readConfidence == 'unsure') 'Title read is a guess — check the spine',
      if (it.flag.isNotEmpty) '${it.stop ? 'STOP' : 'Note'}: ${it.flag}',
      it.status,
      if (it.trend.isNotEmpty) it.trend,
      if (it.note.isNotEmpty) it.note,
    ];
    return Card(
      child: ExpansionTile(
        leading: Container(
          width: 54,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: _color(v).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(_label(v),
              textAlign: TextAlign.center,
              style: TextStyle(color: _color(v), fontWeight: FontWeight.bold, fontSize: 12)),
        ),
        title: Text(it.name),
        subtitle: Text(sub.join('\n'), style: tt.bodySmall),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(it.level == null ? (it.done ? 'no comps' : '') : _m(it.level),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            if (p != null)
              Text('${p >= 0 ? '+' : '−'}\$${p.abs().toStringAsFixed(2)}',
                  style: tt.bodySmall?.copyWith(color: p >= 0 ? Colors.green : Colors.red)),
          ],
        ),
        children: [
          for (final s in it.sales)
            ListTile(
              dense: true,
              title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${s.date} · ${s.condition} · ${_m(s.price)} + ${_m(s.shipping)}'),
              trailing: Text(_m(s.total)),
            ),
          if (it.fromDb && it.sales.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Price from the database (${it.dbAgeDays}d old). Open the sold search to see the sales.',
                  style: tt.bodySmall),
            ),
          TextButton.icon(
            onPressed: () => _open(it.soldUrl),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open eBay sold search'),
          ),
        ],
      ),
    );
  }
}
