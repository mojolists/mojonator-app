import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../settings.dart';

class HistoryScreen extends StatefulWidget {
  final SettingsStore store;
  const HistoryScreen({super.key, required this.store});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<SeenItem>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await widget.store.loadSeen();
    if (mounted) setState(() => _items = items);
  }

  Future<void> _remove(SeenItem it) async {
    final items = List.of(_items ?? const <SeenItem>[])..removeWhere((e) => e.id == it.id);
    await widget.store.saveSeen(items);
    await _load();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
            'Every item will be eligible to be reported again on the next scan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      await widget.store.clearSeen();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reported items'),
        actions: [
          if (items != null && items.isNotEmpty)
            IconButton(
              tooltip: 'Clear all',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(child: Text('Nothing reported yet.'))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, i) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final it = items[i];
                    final d = it.when;
                    final date =
                        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                    return ListTile(
                      title: Text(it.title),
                      subtitle: Text(
                        '$date · ${it.verdict.toUpperCase()} · landed \$${it.landedCost.toStringAsFixed(2)}'
                        '${it.currentLevel == null ? '' : ' · eBay \$${it.currentLevel!.toStringAsFixed(2)}'}'
                        ' · #${it.id}',
                      ),
                      onTap: () {
                        final uri = Uri.tryParse(it.url);
                        if (uri != null) {
                          launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Forget (can be reported again)',
                        onPressed: () => _remove(it),
                      ),
                    );
                  },
                ),
    );
  }
}
