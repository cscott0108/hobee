import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'gallery_export.dart';
import 'saved.dart';
import 'viewer.dart';

/// Settings entry for the private gallery.
class SavedGalleryTile extends StatelessWidget {
  const SavedGalleryTile({super.key});
  @override
  Widget build(BuildContext context) => ListTile(
        key: const Key('open-gallery'),
        leading: const Icon(Icons.photo_library_outlined),
        title: const Text('Hobees gallery'),
        subtitle: const Text('Pictures and videos you saved privately. Export or share them from here.'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SavedGalleryScreen())),
      );
}

enum ExportMode { files, zip }

/// The private Hobees gallery: what you saved, newest first. Tap to view (same zoomable viewer as the feeds),
/// long-press to select several, then share, export (one by one to the phone gallery, or one .zip) or delete.
class SavedGalleryScreen extends StatefulWidget {
  const SavedGalleryScreen({super.key});
  @override
  State<SavedGalleryScreen> createState() => _SavedGalleryScreenState();
}

class _SavedGalleryScreenState extends State<SavedGalleryScreen> {
  List<SavedItem>? items;
  final sel = <int>{};
  bool busy = false;

  bool get selecting => sel.isNotEmpty;
  List<SavedItem> get chosen => [for (final it in items ?? const <SavedItem>[]) if (sel.contains(it.id)) it];

  @override
  void initState() {
    super.initState();
    SavedStore.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    SavedStore.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final all = await SavedStore.all();
    if (!mounted) return;
    setState(() {
      items = all;
      sel.retainAll({for (final it in all) it.id});
    });
  }

  void _toggle(SavedItem it) => setState(() => sel.contains(it.id) ? sel.remove(it.id) : sel.add(it.id!));

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void _open(int i) {
    final list = items!;
    Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(
      entries: [for (final it in list) Entry(it.post, it.media, 0)],
      start: i,
      local: true,
      actions: (c, e) {
        final it = list.firstWhere((x) => x.path == e.item.url);
        return [
          IconButton(key: const Key('viewer-share'), tooltip: 'Share', icon: const Icon(Icons.share), onPressed: () => _share([it])),
          IconButton(key: const Key('viewer-export'), tooltip: 'Export to phone gallery', icon: const Icon(Icons.save_alt),
              onPressed: () => _export([it], ExportMode.files, false, c)),
          if (it.permalink.isNotEmpty)
            IconButton(tooltip: 'Open source post', icon: const Icon(Icons.open_in_new), onPressed: () => _openPost(it)),
          IconButton(key: const Key('viewer-delete'), tooltip: 'Delete', icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await _confirmDelete(c, 1)) return;
                if (c.mounted) Navigator.pop(c);
                await SavedStore.remove([it]);
              }),
        ];
      },
    )));
  }

  Future<void> _openPost(SavedItem it) =>
      launchUrl(Uri.parse('https://www.reddit.com${it.permalink}'), mode: LaunchMode.externalApplication);

  Future<void> _share(List<SavedItem> list) async {
    try {
      await GalleryExport.share(list);
    } catch (e) {
      if (mounted) _snack('Share failed: $e');
    }
  }

  Future<bool> _confirmDelete(BuildContext c, int n) async =>
      await showDialog<bool>(
        context: c,
        builder: (d) => AlertDialog(
          title: Text(n == 1 ? 'Delete this item?' : 'Delete $n items?'),
          content: const Text('They are removed from Hobees for good. Export first if you want to keep a copy.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            TextButton(key: const Key('delete-go'), onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
          ],
        ),
      ) ??
      false;

  Future<void> _delete() async {
    final list = chosen;
    if (!await _confirmDelete(context, list.length)) return;
    await SavedStore.remove(list);
    if (mounted) setState(sel.clear);
  }

  /// Asks how to export the selection: individual files to the phone gallery or one .zip, and whether to
  /// remove them from Hobees afterwards.
  Future<void> _exportDialog() async {
    final list = chosen;
    var mode = ExportMode.files;
    var remove = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) {
          Widget choice(ExportMode m, String title, String sub, Key k) => ListTile(
                key: k,
                contentPadding: EdgeInsets.zero,
                leading: Icon(mode == m ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(title),
                subtitle: Text(sub),
                onTap: () => set(() => mode = m),
              );
          return AlertDialog(
            title: Text('Export ${list.length} item${list.length == 1 ? '' : 's'}'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              choice(ExportMode.files, 'Individual files', 'Into Pictures / Movies, so they show in the phone’s gallery.', const Key('export-files')),
              choice(ExportMode.zip, 'One .zip file', 'Into Downloads, all in one file.', const Key('export-zip')),
              CheckboxListTile(
                key: const Key('export-remove'),
                contentPadding: EdgeInsets.zero,
                value: remove,
                title: const Text('Remove from Hobees after export'),
                onChanged: (v) => set(() => remove = v ?? false),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
              TextButton(key: const Key('export-go'), onPressed: () => Navigator.pop(d, true), child: const Text('Export')),
            ],
          );
        },
      ),
    );
    if (go == true) await _export(list, mode, remove, null);
  }

  Future<void> _export(List<SavedItem> list, ExportMode mode, bool remove, BuildContext? from) async {
    final m = ScaffoldMessenger.of(from ?? context);
    setState(() => busy = true);
    try {
      if (mode == ExportMode.zip) {
        await GalleryExport.toZip(list);
        if (remove) await SavedStore.remove(list);
        m.showSnackBar(SnackBar(content: Text('Saved a .zip of ${list.length} to Downloads')));
      } else {
        final done = await GalleryExport.toPhone(list);
        if (remove) await SavedStore.remove(done);
        m.showSnackBar(SnackBar(content: Text('Exported ${done.length}/${list.length} to the phone gallery')));
      }
      if (mounted) setState(sel.clear);
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = items;
    final one = chosen.length == 1 ? chosen.single : null;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (did, _) {
        if (!did) setState(sel.clear); // Back first ends the selection
      },
      child: Scaffold(
        appBar: selecting
            ? AppBar(
                leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Done', onPressed: () => setState(sel.clear)),
                title: Text('${sel.length} selected'),
                actions: [
                  IconButton(key: const Key('select-all'), tooltip: 'Select all', icon: const Icon(Icons.select_all),
                      onPressed: () => setState(() => sel.addAll({for (final it in list!) it.id!}))),
                  IconButton(key: const Key('sel-share'), tooltip: 'Share', icon: const Icon(Icons.share), onPressed: busy ? null : () => _share(chosen)),
                  IconButton(key: const Key('sel-export'), tooltip: 'Export', icon: const Icon(Icons.save_alt), onPressed: busy ? null : _exportDialog),
                  if (one != null && one.permalink.isNotEmpty)
                    IconButton(tooltip: 'Open source post', icon: const Icon(Icons.open_in_new), onPressed: () => _openPost(one)),
                  IconButton(key: const Key('sel-delete'), tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: busy ? null : _delete),
                ],
              )
            : AppBar(title: Text(list == null || list.isEmpty ? 'Hobees gallery' : 'Hobees gallery · ${list.length}')),
        body: Column(children: [
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: list == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                    ? const Center(
                        child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('Nothing saved yet. Pictures and videos you download from the viewer land here.', textAlign: TextAlign.center),
                      ))
                    : GridView.builder(
                        padding: const EdgeInsets.all(2),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
                        itemCount: list.length,
                        itemBuilder: (_, i) => _Tile(
                          key: Key('saved-tile-$i'),
                          item: list[i],
                          selected: sel.contains(list[i].id),
                          onTap: () => selecting ? _toggle(list[i]) : _open(i),
                          onLongPress: () => _toggle(list[i]),
                        ),
                      ),
          ),
        ]),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final SavedItem item;
  final bool selected;
  final VoidCallback onTap, onLongPress;
  const _Tile({super.key, required this.item, required this.selected, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final pic = item.media.thumb;
    final d = item.duration;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(fit: StackFit.expand, children: [
        ColoredBox(
          color: Colors.black12,
          child: pic.isEmpty
              ? const Icon(Icons.movie_outlined)
              : Image(image: gridThumbProvider(pic), fit: BoxFit.cover, gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Icon(item.isVideo ? Icons.movie_outlined : Icons.broken_image_outlined)),
        ),
        if (item.isVideo)
          Positioned(
            right: 4, top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 16),
                if (d != null && d > 0)
                  Text('${d ~/ 60}:${(d % 60).floor().toString().padLeft(2, '0')}', style: const TextStyle(color: Colors.white, fontSize: 11)),
              ]),
            ),
          ),
        if (selected) ...[
          ColoredBox(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)),
          const Positioned(left: 4, top: 4, child: Icon(Icons.check_circle, color: Colors.white)),
        ],
      ]),
    );
  }
}
