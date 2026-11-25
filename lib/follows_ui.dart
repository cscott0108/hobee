import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'age.dart';
import 'following.dart';
import 'follows.dart';
import 'pace_log.dart' show saveTextToDownloads;

Future<String?> _askName(BuildContext context, String title, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'Profile name'), onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

/// Settings → Following lists: profiles, their subreddits/users, import and export.
class FollowsScreen extends StatefulWidget {
  const FollowsScreen({super.key});
  @override
  State<FollowsScreen> createState() => _FollowsScreenState();
}

class _FollowsScreenState extends State<FollowsScreen> {
  List<Profile> profiles = const [];
  int? shown;
  List<Follow> follows = const [];
  String filter = '';
  Map<String, FollowState> states = const {};
  ChannelHealth? only; // status filter (null: all)
  String sortBy = 'name'; // name, post, checked, status

  @override
  void initState() {
    super.initState();
    FollowStore.version.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    FollowStore.version.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final ps = await FollowStore.profiles();
    final id = ps.any((p) => p.id == shown) ? shown! : (ps.any((p) => p.id == FollowStore.active.value) ? FollowStore.active.value! : ps.first.id);
    final fs = await FollowStore.follows(id);
    final st = await Following.statesOf(id);
    if (!mounted) return;
    setState(() {
      profiles = ps;
      shown = id;
      follows = fs;
      states = st;
    });
  }

  Future<void> _newProfile() async {
    final n = (await _askName(context, 'New profile'))?.trim() ?? '';
    if (n.isEmpty) return;
    try {
      shown = await FollowStore.createProfile(n);
    } catch (_) {
      _snack('A profile named "$n" already exists');
    }
  }

  Future<void> _rename() async {
    final cur = profiles.firstWhere((p) => p.id == shown);
    final n = (await _askName(context, 'Rename profile', initial: cur.name))?.trim() ?? '';
    if (n.isEmpty || n == cur.name) return;
    try {
      await FollowStore.renameProfile(cur.id, n);
    } catch (_) {
      _snack('A profile named "$n" already exists');
    }
  }

  Future<void> _delete() async {
    final cur = profiles.firstWhere((p) => p.id == shown);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${cur.name}"?'),
        content: Text('Its ${follows.length} subreddits and users are removed from Hobees. Other profiles are not touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    shown = null;
    if (!await FollowStore.deleteProfile(cur.id)) _snack('The last profile can\'t be deleted');
  }

  Future<void> _export({required bool csv}) async {
    final name = profiles.firstWhere((p) => p.id == shown).name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Save list',
        fileName: 'hobees_$name.${csv ? 'csv' : 'txt'}',
        bytes: utf8.encode(exportFollows(follows, csv: csv)),
        mimeType: csv ? 'text/csv' : 'text/plain',
      );
      if (saved != null) _snack('Saved ${follows.length} entries');
    } catch (e) {
      _snack('Couldn\'t save: $e');
    }
  }

  Future<void> _report() async {
    final name = profiles.firstWhere((p) => p.id == shown).name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    try {
      await saveTextToDownloads('Hobees_channels_$name', 'csv', channelReportCsv(follows, states, DateTime.now().millisecondsSinceEpoch));
      _snack('Saved the channel report to Downloads');
    } catch (e) {
      _snack("Couldn't save: $e");
    }
  }

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = filter.toLowerCase();
    final now = DateTime.now().millisecondsSinceEpoch;
    ChannelHealth h(Follow x) => healthOf(states[x.key] ?? FollowState(), now);
    final counts = <ChannelHealth, int>{};
    for (final x in follows) {
      counts[h(x)] = (counts[h(x)] ?? 0) + 1;
    }
    final list = [
      for (final x in follows)
        if ((f.isEmpty || x.name.toLowerCase().contains(f)) && (only == null || h(x) == only)) x
    ];
    int newest(Follow x) => states[x.key]?.newest ?? 0;
    int checked(Follow x) => states[x.key]?.at ?? 0;
    switch (sortBy) {
      case 'post':
        list.sort((a, b) => newest(b).compareTo(newest(a)));
      case 'checked':
        list.sort((a, b) => checked(a).compareTo(checked(b)));
      case 'status':
        const order = [ChannelHealth.failing, ChannelHealth.dead, ChannelHealth.quiet, ChannelHealth.unchecked, ChannelHealth.active];
        list.sort((a, b) => order.indexOf(h(a)).compareTo(order.indexOf(h(b))));
    }
    final subs = follows.where((x) => x.kind == FollowKind.sub).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Following lists'),
        actions: [
          IconButton(
            tooltip: 'Import',
            icon: const Icon(Icons.playlist_add),
            onPressed: shown == null ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => ImportScreen(profile: shown!))),
          ),
          PopupMenuButton<String>(
            key: const Key('channels-sort'),
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            initialValue: sortBy,
            onSelected: (v) => setState(() => sortBy = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'name', child: Text('By name')),
              PopupMenuItem(value: 'post', child: Text('Newest post first')),
              PopupMenuItem(value: 'checked', child: Text('Longest since checked')),
              PopupMenuItem(value: 'status', child: Text('Problems first')),
            ],
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'report' => _report(),
              'new' => _newProfile(),
              'rename' => _rename(),
              'delete' => _delete(),
              'txt' => _export(csv: false),
              'csv' => _export(csv: true),
              'copy' => Clipboard.setData(ClipboardData(text: exportFollows(follows))).then((_) => _snack('Copied ${follows.length} entries')),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'new', child: Text('New profile')),
              PopupMenuItem(value: 'rename', child: Text('Rename profile')),
              PopupMenuItem(value: 'delete', child: Text('Delete profile')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'txt', child: Text('Export as text')),
              PopupMenuItem(value: 'csv', child: Text('Export as CSV')),
              PopupMenuItem(value: 'copy', child: Text('Copy to clipboard')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'report', child: Text('Save channel report')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 56,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
            for (final p in profiles)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(p.name), selected: p.id == shown, onSelected: (_) {
                  shown = p.id;
                  _reload();
                }),
              ),
            ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('New'), onPressed: _newProfile),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(child: Text('$subs subreddits · ${follows.length - subs} users', style: TextStyle(color: cs.onSurfaceVariant))),
            if (shown != null && shown != FollowStore.active.value)
              TextButton(onPressed: () => FollowStore.setActive(shown!).then((_) => setState(() {})), child: const Text('Use in Following'))
            else
              Text('Shown in Following', style: TextStyle(color: cs.primary, fontSize: 12)),
          ]),
        ),
        if (follows.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final (k, label) in [
                (null, 'All'),
                (ChannelHealth.active, 'Active'),
                (ChannelHealth.quiet, 'Quiet'),
                (ChannelHealth.dead, 'Dead'),
                (ChannelHealth.failing, 'Failing'),
                (ChannelHealth.unchecked, 'Not checked'),
              ])
                if (k == null || (counts[k] ?? 0) > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: Key('health-${k?.name ?? 'all'}'),
                      label: Text('$label ${k == null ? follows.length : counts[k]}'),
                      selected: only == k,
                      onSelected: (_) => setState(() => only = k),
                    ),
                  ),
            ]),
          ),
        if (follows.length > 12)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter', isDense: true, border: OutlineInputBorder()),
              onChanged: (v) => setState(() => filter = v),
            ),
          ),
        Expanded(
          child: follows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('No subreddits or users yet.', style: TextStyle(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: shown == null ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => ImportScreen(profile: shown!))),
                        icon: const Icon(Icons.playlist_add),
                        label: const Text('Import a list'),
                      ),
                    ]),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final x = list[i];
                    final st = states[x.key];
                    return ListTile(
                      dense: true,
                      leading: Icon(x.kind == FollowKind.sub ? Icons.forum_outlined : Icons.person_outline),
                      title: Row(children: [
                        Flexible(child: Text(x.label, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        _HealthTag(h(x)),
                      ]),
                      subtitle: Text(channelLine(st, now), key: Key('channel-line-${x.key}'), maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close),
                        onPressed: () => Following.unfollow(shown!, x),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

/// Paste text or pick a .txt/.csv file, preview what was found, then save it into a profile.
class ImportScreen extends StatefulWidget {
  final int profile;
  const ImportScreen({super.key, required this.profile});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final text = TextEditingController();
  ImportResult result = const ImportResult([], []);
  List<Profile> profiles = const [];
  late int target = widget.profile;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    text.addListener(() => setState(() => result = parseFollowList(text.text)));
    FollowStore.profiles().then((ps) => mounted ? setState(() => profiles = ps) : null);
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) text.text = d!.text!;
  }

  Future<void> _pick() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'csv']);
      if (files.isEmpty) return;
      text.text = utf8.decode(await files.first.readAsBytes(), allowMalformed: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t read the file: $e')));
    }
  }

  Future<void> _newTarget() async {
    final n = (await _askName(context, 'New profile'))?.trim() ?? '';
    if (n.isEmpty) return;
    try {
      final id = await FollowStore.createProfile(n);
      final ps = await FollowStore.profiles();
      setState(() {
        profiles = ps;
        target = id;
      });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('A profile named "$n" already exists')));
    }
  }

  Future<void> _save() async {
    setState(() => saving = true);
    final added = await FollowStore.add(target, result.follows);
    if (!mounted) return;
    final name = profiles.where((p) => p.id == target).map((p) => p.name).firstOrNull ?? 'profile';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Added $added to $name${added < result.follows.length ? ' (${result.follows.length - added} were already there)' : ''}')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = result;
    return Scaffold(
      appBar: AppBar(title: const Text('Import list')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Paste subreddits and users, or pick a .txt / .csv file. Accepts r/name, u/name, reddit links, '
            'multireddit links like reddit.com/r/a+b+c, u_name entries, and Reddit\'s subscribed_subreddits.csv.',
            style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(height: 12),
        Row(children: [
          OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: const Text('Paste')),
          const SizedBox(width: 8),
          OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.file_open_outlined), label: const Text('Pick file')),
        ]),
        const SizedBox(height: 12),
        TextField(
          key: const Key('import-text'),
          controller: text,
          minLines: 4,
          maxLines: 8,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'r/pics u/someone https://reddit.com/r/a+b+c'),
        ),
        const SizedBox(height: 16),
        Text(
          r.follows.isEmpty && r.skipped.isEmpty ? 'Nothing found yet' : 'Found ${r.subs} subreddits and ${r.users} users${r.skipped.isEmpty ? '' : ' · ${r.skipped.length} skipped'}',
          key: const Key('import-summary'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (r.skipped.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Skipped: ${r.skipped.take(10).join(', ')}${r.skipped.length > 10 ? ' …' : ''}', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          ),
        if (r.follows.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Show list'),
            children: [
              Wrap(spacing: 6, runSpacing: 6, children: [for (final f in r.follows.take(500)) Chip(label: Text(f.label), visualDensity: VisualDensity.compact)]),
              if (r.follows.length > 500) Text('… and ${r.follows.length - 500} more'),
            ],
          ),
        const SizedBox(height: 16),
        Row(children: [
          const Text('Save to '),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<int>(
              isExpanded: true,
              value: profiles.any((p) => p.id == target) ? target : null,
              items: [for (final p in profiles) DropdownMenuItem(value: p.id, child: Text(p.name))],
              onChanged: (v) => setState(() => target = v ?? target),
            ),
          ),
          TextButton(onPressed: _newTarget, child: const Text('New profile')),
        ]),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('import-save'),
          onPressed: r.follows.isEmpty || saving ? null : _save,
          child: Text(r.follows.isEmpty ? 'Save' : 'Save ${r.follows.length}'),
        ),
      ]),
    );
  }
}

String _ago(int ms, int now) {
  final a = shortAge(ms ~/ 1000, now: DateTime.fromMillisecondsSinceEpoch(now));
  return a == 'now' ? 'just now' : '$a ago';
}

/// The status line under a channel: last post, last check, next check, posts saved, failures.
String channelLine(FollowState? s, int now) {
  if (s == null || s.at == 0) return 'Not checked yet';
  final next = Following.nextCheck(s, now);
  final left = next?.difference(DateTime.fromMillisecondsSinceEpoch(now));
  final due = left == null
      ? ''
      : left.isNegative
          ? 'due now'
          : left.inMinutes < 60
              ? 'next in ${left.inMinutes + 1} min'
              : 'next in ${left.inHours} h';
  return [
    s.newest == null ? 'no posts found' : 'last post ${_ago(s.newest! * 1000, now)}',
    'checked ${_ago(s.at, now)}',
    if (due.isNotEmpty) due,
    '${s.n} saved',
    if (s.fails > 0) 'failed ${s.fails}× (${s.err ?? 'unknown'})',
  ].join(' · ');
}

class _HealthTag extends StatelessWidget {
  final ChannelHealth h;
  const _HealthTag(this.h);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color) = switch (h) {
      ChannelHealth.active => ('Active', Colors.green),
      ChannelHealth.quiet => ('Quiet', Colors.amber.shade700),
      ChannelHealth.dead => ('Dead', cs.outline),
      ChannelHealth.failing => ('Failing', cs.error),
      ChannelHealth.unchecked => ('Not checked', cs.outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
