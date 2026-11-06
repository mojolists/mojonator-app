import 'package:flutter/material.dart';

import '../models.dart';
import '../scanner.dart';
import '../settings.dart';
import 'history_screen.dart';
import 'result_card.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = SettingsStore();
  AppSettings? _settings;
  List<SeenItem> _seen = [];
  Scanner? _running;
  ScanResult? _result;
  final List<String> _log = [];
  final _logCtl = ScrollController();
  bool _showLog = true;
  bool _showRejected = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await _store.load();
    final seen = await _store.loadSeen();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _seen = seen;
    });
    if (!s.hasKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openSettings());
    }
  }

  Future<void> _openSettings() async {
    final s = _settings;
    if (s == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SettingsScreen(settings: s, store: _store)),
    );
    if (changed == true) await _load();
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HistoryScreen(store: _store)),
    );
    final seen = await _store.loadSeen();
    if (mounted) setState(() => _seen = seen);
  }

  Future<void> _scan() async {
    final s = _settings;
    if (s == null || _running != null) return;
    if (!s.hasKey) {
      await _openSettings();
      return;
    }
    setState(() {
      _log.clear();
      _result = null;
      _showLog = true;
    });
    final scanner = Scanner(
      settings: s,
      seen: _seen,
      onProgress: (m) {
        if (!mounted) return;
        setState(() => _log.add(m));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logCtl.hasClients) {
            _logCtl.jumpTo(_logCtl.position.maxScrollExtent);
          }
        });
      },
    );
    setState(() => _running = scanner);
    final result = await scanner.run();
    // Record deals and borderline items so the next scan can skip them.
    final now = DateTime.now();
    final additions = result.results
        .where((r) => r.verdict == Verdict.deal || r.verdict == Verdict.borderline)
        .map((r) => SeenItem(
              id: r.listing.id,
              title: r.listing.title,
              when: now,
              verdict: r.verdict.name,
              landedCost: r.landedCost,
              currentLevel: r.currentLevel,
              url: r.listing.url,
            ))
        .toList();
    if (additions.isNotEmpty) {
      final ids = additions.map((e) => e.id).toSet();
      final merged = [
        ...additions,
        ..._seen.where((e) => !ids.contains(e.id)),
      ];
      await _store.saveSeen(merged);
      _seen = await _store.loadSeen();
    }
    if (!mounted) return;
    setState(() {
      _running = null;
      _result = result;
      _showLog = result.fatalError != null || result.results.isEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final running = _running != null;
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vinted Scout'),
        actions: [
          IconButton(
            tooltip: 'History of reported items',
            icon: const Icon(Icons.history),
            onPressed: _openHistory,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: running ? null : _scan,
                          icon: running
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.search),
                          label: Text(running ? 'Scanning…' : 'Scan Vinted now'),
                          style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16)),
                        ),
                      ),
                      if (running) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => _running?.cancel(),
                          child: const Text('Stop'),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _summaryLine(s),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    children: [
                      if (r != null) ..._resultSection(context, r),
                      if (_log.isNotEmpty) _logPanel(context),
                      if (r == null && _log.isEmpty) _idleHint(context),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  String _summaryLine(AppSettings s) {
    final on = s.searches.where((e) => e.enabled).map((e) => e.format).join(', ');
    return '$on · ${s.pagesPerSearch} page(s) each · newest first · '
        '${s.includeVeryGood ? 'NWT / NWOT / Very good' : 'NWT / NWOT'} · '
        'up to ${s.maxCandidates} comps · ${s.model}';
  }

  Widget _idleHint(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Tap Scan. The app reads the newest Vinted listings for each format, '
          'has Claude pick the candidates worth comping, pulls the real eBay '
          'Sold Items results for each, and reads the price trend. A deal means '
          'the current selling level is at least double the landed cost and '
          '\$15 above it.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );

  List<Widget> _resultSection(BuildContext context, ScanResult r) {
    final deals = r.deals;
    final border = r.borderline;
    final rejected = r.rejected;
    final errors = r.errors;
    final mins = r.finishedAt.difference(r.startedAt).inSeconds;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(
          r.fatalError != null
              ? 'Scan stopped: ${r.fatalError}'
              : '${r.listingsRead} listings on ${r.pagesRead} pages · '
                  '${r.results.length} comped · ${mins}s',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      if (deals.isEmpty && border.isEmpty && r.fatalError == null)
        const Card(
          child: ListTile(
            leading: Icon(Icons.check_circle_outline),
            title: Text('No qualifying deals this run.'),
          ),
        ),
      if (deals.isNotEmpty) _header(context, 'Deals (${deals.length})', Colors.green),
      ...deals.map((e) => ResultCard(result: e)),
      if (border.isNotEmpty)
        _header(context, 'Borderline (${border.length})', Colors.orange),
      ...border.map((e) => ResultCard(result: e)),
      if (rejected.isNotEmpty || errors.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextButton.icon(
            onPressed: () => setState(() => _showRejected = !_showRejected),
            icon: Icon(_showRejected ? Icons.expand_less : Icons.expand_more),
            label: Text(
                '${_showRejected ? 'Hide' : 'Show'} comped-and-rejected (${rejected.length})'
                '${errors.isEmpty ? '' : ' and errors (${errors.length})'}'),
          ),
        ),
      if (_showRejected) ...[
        ...rejected.map((e) => ResultCard(result: e, compact: true)),
        ...errors.map((e) => ResultCard(result: e, compact: true)),
      ],
    ];
  }

  Widget _header(BuildContext context, String text, Color color) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: color, fontWeight: FontWeight.bold)),
      );

  Widget _logPanel(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            title: const Text('Scan log'),
            trailing: Icon(_showLog ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _showLog = !_showLog),
          ),
          if (_showLog)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: Scrollbar(
                controller: _logCtl,
                child: ListView.builder(
                  controller: _logCtl,
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
