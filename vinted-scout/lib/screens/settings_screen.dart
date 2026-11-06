import 'package:flutter/material.dart';

import '../settings.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final SettingsStore store;
  const SettingsScreen({super.key, required this.settings, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _pages;
  late final TextEditingController _max;
  late final TextEditingController _ship;
  late final TextEditingController _minLanded;
  late final TextEditingController _rules;
  late final TextEditingController _newFormat;
  late final TextEditingController _newTerm;
  late List<SearchSpec> _searches;
  late bool _veryGood;
  late bool _skipSeen;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _key = TextEditingController(text: s.apiKey);
    _model = TextEditingController(text: s.model);
    _pages = TextEditingController(text: '${s.pagesPerSearch}');
    _max = TextEditingController(text: '${s.maxCandidates}');
    _ship = TextEditingController(text: s.shippingAssumption.toStringAsFixed(2));
    _minLanded = TextEditingController(text: s.minLandedCost.toStringAsFixed(2));
    _rules = TextEditingController(text: s.extraRules);
    _newFormat = TextEditingController();
    _newTerm = TextEditingController();
    _searches = List.of(s.searches);
    _veryGood = s.includeVeryGood;
    _skipSeen = s.skipSeen;
  }

  @override
  void dispose() {
    for (final c in [_key, _model, _pages, _max, _ship, _minLanded, _rules, _newFormat, _newTerm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final s = widget.settings;
    s.apiKey = _key.text.trim();
    s.model = _model.text.trim().isEmpty ? 'claude-sonnet-5-5' : _model.text.trim();
    s.pagesPerSearch = (int.tryParse(_pages.text) ?? 2).clamp(1, 5);
    s.maxCandidates = (int.tryParse(_max.text) ?? 8).clamp(1, 20);
    s.shippingAssumption = (double.tryParse(_ship.text) ?? 5.0).clamp(0, 50);
    s.minLandedCost = (double.tryParse(_minLanded.text) ?? 8.0).clamp(0, 500);
    s.includeVeryGood = _veryGood;
    s.skipSeen = _skipSeen;
    s.extraRules = _rules.text;
    s.searches = _searches;
    await widget.store.save(s);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Claude', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: !_showKey,
            decoration: InputDecoration(
              labelText: 'Anthropic API key',
              helperText: 'Stored on this device only (secure storage). Needed for candidate picking and comp reading.',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: 'Model',
              helperText: 'e.g. claude-sonnet-5-5 (cheaper) or claude-opus-5-5 (sharper)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Text('Vinted searches', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Each search is read newest-first for the number of pages below.',
              style: Theme.of(context).textTheme.bodySmall),
          ..._searches.asMap().entries.map((e) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(e.value.format),
                subtitle: Text('search: "${e.value.term}"'),
                value: e.value.enabled,
                onChanged: (v) => setState(
                    () => _searches[e.key] = e.value.copyWith(enabled: v)),
                secondary: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => _searches.removeAt(e.key)),
                ),
              )),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newFormat,
                  decoration: const InputDecoration(
                      labelText: 'Label', hintText: 'e.g. 4K'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _newTerm,
                  decoration: const InputDecoration(
                      labelText: 'Vinted search text', hintText: 'e.g. 4k steelbook'),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () {
                  final f = _newFormat.text.trim();
                  final t = _newTerm.text.trim();
                  if (t.isEmpty) return;
                  setState(() {
                    _searches.add(SearchSpec(f.isEmpty ? t : f, t));
                    _newFormat.clear();
                    _newTerm.clear();
                  });
                },
              ),
            ],
          ),
          TextButton(
            onPressed: () =>
                setState(() => _searches = AppSettings.defaultSearches()),
            child: const Text('Reset to Blu-ray / CD / Cassette'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pages,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Pages per search', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _max,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Max candidates to comp',
                      border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include "Very good" (used) listings'),
            subtitle: const Text('Off = New with tags / New without tags only'),
            value: _veryGood,
            onChanged: (v) => setState(() => _veryGood = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Skip items already reported'),
            subtitle: const Text('Uses the History list; clear it there to re-check everything'),
            value: _skipSeen,
            onChanged: (v) => setState(() => _skipSeen = v),
          ),
          const SizedBox(height: 16),
          Text('Money rules', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ship,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Assumed Vinted shipping (\$)',
                      helperText: 'Added to the incl. price unless the listing is free-ship',
                      border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _minLanded,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Ignore under landed (\$)',
                      helperText: 'Cheap commons are never worth comping',
                      border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Deal test (fixed): eBay current selling level ≥ 2 × landed cost AND ≥ \$15 above it, '
            'read from the newest same-edition sold comps including their shipping.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _rules,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Extra rules for Claude (optional)',
              hintText: 'e.g. "Always comp Criterion even under \$8" or "Skip anime"',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
