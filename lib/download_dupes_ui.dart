import 'dart:io';
import 'package:flutter/material.dart';
import 'download_dupes.dart';
import 'models.dart';
import 'saved.dart';
import 'viewer.dart';

String _when(int? created) {
  if (created == null || created <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(created * 1000).toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String _from(String author, String sub, int? created) =>
    [if (author.isNotEmpty) 'u/$author', if (sub.isNotEmpty) 'r/$sub', _when(created)].where((x) => x.isNotEmpty).join(' · ');

/// A preview: a local file (Hobees gallery) or a URL; a plain icon when there's nothing to show.
Widget _picture(String? src, {double height = 200}) {
  Widget fallback(BuildContext c, Object e, StackTrace? s) => const Center(child: Icon(Icons.image_not_supported_outlined));
  final Widget img = src == null || src.isEmpty
      ? const Center(child: Icon(Icons.image_outlined))
      : src.startsWith('/')
          ? Image.file(File(src), fit: BoxFit.contain, cacheWidth: 600, errorBuilder: fallback)
          : Image.network(src, fit: BoxFit.contain, cacheWidth: 600, errorBuilder: fallback);
  return SizedBox(height: height, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: ColoredBox(color: Colors.black12, child: img)));
}

class _Side extends StatelessWidget {
  final String heading, detail, where;
  final Widget picture;
  const _Side(this.heading, this.picture, this.detail, this.where);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(heading, style: t.labelLarge),
      const SizedBox(height: 4),
      picture,
      const SizedBox(height: 4),
      if (detail.isNotEmpty) Text(detail, style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
      if (where.isNotEmpty) Text(where, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }
}

String _where(DupMatch d) => d.savedPath != null ? 'In the Hobees gallery' : 'Saved to the phone gallery';

String _strength(DupMatch d) => switch (d.kind) {
      DupKind.same => 'Same file',
      DupKind.exact => 'Exact match',
      DupKind.similar => 'Similar (${d.bits} of 64 fingerprint bits differ)',
    };

/// Shows the earlier download: its file in the Hobees gallery viewer, or else its preview full screen.
Future<void> openEarlier(BuildContext context, DupMatch d) async {
  if (d.savedPath != null) {
    final items = await SavedStore.all();
    final it = items.where((x) => x.path == d.savedPath).firstOrNull;
    if (it != null && context.mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(entries: [Entry(it.post, it.media, 0)], start: 0, local: true)));
      return;
    }
  }
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (c) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('Earlier download')),
        body: InteractiveViewer(maxScale: 6, child: Center(child: _picture(d.image, height: MediaQuery.sizeOf(c).height * 0.8))),
      ),
    ),
  );
}

/// One download that looks like an earlier one: both side by side. True = download anyway.
Future<bool> confirmDuplicate(BuildContext context, MediaItem m, Post post, DupMatch d) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      key: const Key('dup-dialog'),
      title: Text(d.label),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_strength(d), style: Theme.of(c).textTheme.bodyMedium),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _Side('This one', _picture(m.thumb.isEmpty ? m.url : m.thumb), _from(post.author, post.subreddit, post.created), '')),
            const SizedBox(width: 10),
            Expanded(child: _Side('Earlier', _picture(d.image), _from(d.author, d.subreddit, d.created), _where(d))),
          ]),
        ]),
      ),
      actions: [
        TextButton(key: const Key('dup-open'), onPressed: () => openEarlier(c, d), child: const Text('Open earlier')),
        TextButton(key: const Key('dup-cancel'), onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(key: const Key('dup-download'), onPressed: () => Navigator.pop(c, true), child: const Text('Download anyway')),
      ],
    ),
  );
  return r == true;
}

enum DupChoice { skip, all }

/// Several downloads of which [dups] look like earlier ones: skip those, download all, or cancel (null).
Future<DupChoice?> confirmDuplicates(BuildContext context, List<(MediaItem, DupMatch)> dups, int total) => showDialog<DupChoice>(
      context: context,
      builder: (c) => AlertDialog(
        key: const Key('dups-dialog'),
        title: Text('${dups.length} of $total look like earlier downloads'),
        content: SizedBox(
          width: double.maxFinite,
          height: (dups.length * 150.0).clamp(150.0, 450.0),
          child: ListView.separated(
            itemCount: dups.length,
            separatorBuilder: (_, _) => const Divider(height: 16),
            itemBuilder: (_, i) {
              final (m, d) = dups[i];
              return InkWell(
                onTap: () => openEarlier(c, d),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _Side('This one', _picture(m.thumb.isEmpty ? m.url : m.thumb, height: 110), '', '')),
                  const SizedBox(width: 8),
                  Expanded(child: _Side('Earlier', _picture(d.image, height: 110), _strength(d), _where(d))),
                ]),
              );
            },
          ),
        ),
        actions: [
          TextButton(key: const Key('dups-cancel'), onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(key: const Key('dups-skip'), onPressed: () => Navigator.pop(c, DupChoice.skip), child: const Text('Skip those')),
          FilledButton(key: const Key('dups-all'), onPressed: () => Navigator.pop(c, DupChoice.all), child: const Text('Download all')),
        ],
      ),
    );
