import 'package:flutter/material.dart';
import 'following.dart';
import 'pace_log.dart';

/// Settings entry for the archive pace log.
class PaceLogTile extends StatelessWidget {
  const PaceLogTile({super.key});
  @override
  Widget build(BuildContext context) => ListTile(
        key: const Key('pace-log'),
        leading: const Icon(Icons.query_stats),
        title: const Text('Archive pace'),
        subtitle: const Text('How the archive has been answering: requests, slow-downs and reply times. Save the log to Downloads.'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PaceLogScreen())),
      );
}

String _hm(int t) {
  final d = DateTime.fromMillisecondsSinceEpoch(t).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

class PaceLogScreen extends StatefulWidget {
  const PaceLogScreen({super.key});
  @override
  State<PaceLogScreen> createState() => _PaceLogScreenState();
}

class _PaceLogScreenState extends State<PaceLogScreen> {
  PaceSummary? hour, day;
  List<PaceEntry> problems = const [];
  int total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final h = await PaceLog.since(const Duration(hours: 1));
    final d = await PaceLog.since(const Duration(hours: 24));
    final all = await PaceLog.all();
    if (!mounted) return;
    setState(() {
      hour = PaceSummary.of(h);
      day = PaceSummary.of(d);
      problems = all.where((e) => e.problem).toList().reversed.take(30).toList();
      total = all.length;
    });
  }

  Future<void> _save() async {
    final m = ScaffoldMessenger.of(context);
    try {
      await PaceLog.saveToDownloads();
      m.showSnackBar(const SnackBar(content: Text('Saved to Downloads as Hobees_pace_log_….csv')));
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear the pace log?'),
        content: const Text('Deletes every recorded request. It starts recording again right away.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(key: const Key('pace-clear-ok'), onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    await PaceLog.clear();
    await _load();
  }

  Widget _summary(String title, PaceSummary? s) {
    final t = Theme.of(context).textTheme;
    if (s == null) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.titleSmall),
          const SizedBox(height: 6),
          Text('${s.requests} requests · ${s.ok} ok · average reply ${s.avgReplyMs} ms'),
          Text('${s.slowDowns} slow-downs · ${s.rateLimited} rate-limited (429) · ${s.timeouts} timeouts · ${s.otherProblems} other'),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Archive pace'), actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
                'Now: ${Following.gap.inMilliseconds} ms between Following requests, '
                '${Following.inFlight} at a time${Following.twoAtATime.value ? ' (Faster updates on)' : ''}. '
                '$total entries kept (newest ${PaceLog.keep.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',')}). The log stays on this phone and holds no subreddit or user names.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          ),
          _summary('Last hour', hour),
          _summary('Last 24 hours', day),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              FilledButton.icon(key: const Key('pace-save'), onPressed: _save, icon: const Icon(Icons.download), label: const Text('Save log')),
              const SizedBox(width: 12),
              TextButton(key: const Key('pace-clear'), onPressed: _clear, child: const Text('Clear')),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Recent problems', style: Theme.of(context).textTheme.titleSmall),
          ),
          if (problems.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('None recorded.')),
          for (final e in problems)
            ListTile(
              dense: true,
              title: Text('${_hm(e.t)} · ${e.result.replaceAll('_', ' ')} · ${e.caller}'),
              subtitle: Text([if (e.status > 0) 'HTTP ${e.status}', '${e.replyMs} ms', if (e.net.isNotEmpty) e.net, if (e.note.isNotEmpty) e.note].join(' · '),
                  maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
