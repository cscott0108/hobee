import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'clean.dart';
import 'download.dart';
import 'gallery_export.dart';
import 'saved.dart';

const _media = MethodChannel('hobee/media');

/// Result of a restore: how many items came back, and how many were already in the gallery.
class RestoreResult {
  final int added, skipped;
  const RestoreResult(this.added, this.skipped);
}

/// Back up the whole private gallery as one .zip in Downloads (every file plus a list of where each came from),
/// and restore it into the gallery again, skipping anything that's already there.
class GalleryBackup {
  static const manifestName = 'hobees-gallery.json';
  static const version = 1;

  /// Test seam: a scratch folder for building the list and unpacking a backup.
  static Future<Directory> Function() scratch = () => Directory.systemTemp.createTemp('hobees_backup');

  /// Same item = saved at the same moment from the same post.
  static String _key(int savedAt, String postId) => '$savedAt|$postId';

  /// Writes `Hobees_backup_<date>.zip` to Downloads. Returns where it went.
  static Future<String> backup() async {
    final items = await SavedStore.all();
    if (items.isEmpty) throw StateError('Nothing to back up');
    final names = GalleryExport.zipNames(items);
    final paths = <String>[], entries = <String>[], list = <Map<String, Object?>>[];
    for (var k = 0; k < items.length; k++) {
      final it = items[k];
      String? thumb;
      if (it.thumb != null && await File(it.thumb!).exists()) {
        thumb = 't_${names[k].substring(0, names[k].lastIndexOf('.'))}.jpg';
        paths.add(it.thumb!);
        entries.add(thumb);
      }
      paths.add(it.path);
      entries.add(names[k]);
      final row = it.toRow()
        ..remove('path')
        ..remove('thumb');
      list.add({...row, 'file': names[k], 'thumb': thumb});
    }
    final tmp = await scratch();
    try {
      final mf = File('${tmp.path}/$manifestName');
      await mf.writeAsString(jsonEncode({'hobees_backup': version, 'items': list}));
      await Downloader.askStorage();
      final r = await _media.invokeMethod<String>('zip', {
        'paths': [mf.path, ...paths],
        'names': [manifestName, ...entries],
        'name': 'Hobees_backup_${timestampName(DateTime.now(), 'zip')}',
      });
      return r ?? '';
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  /// Restores a backup from [src] (a content:// uri from the file picker, or a file path).
  /// Throws a [FormatException] if it isn't a Hobees backup.
  static Future<RestoreResult> restore(String src) async {
    final tmp = await scratch();
    try {
      await _media.invokeMethod('unzip', {'src': src, 'dir': tmp.path});
      final mf = File('${tmp.path}/$manifestName');
      if (!await mf.exists()) throw const FormatException('This isn\'t a Hobees gallery backup');
      Object? m;
      try {
        m = jsonDecode(await mf.readAsString());
      } catch (_) {
        throw const FormatException('The backup\'s list is damaged');
      }
      if (m is! Map || m['hobees_backup'] != version || m['items'] is! List) {
        throw const FormatException('This isn\'t a Hobees gallery backup');
      }
      final have = {for (final it in await SavedStore.all()) _key(it.savedAt, it.postId)};
      var added = 0, skipped = 0;
      for (final e in (m['items'] as List).whereType<Map>()) {
        final row = Map<String, Object?>.from(e);
        final name = row.remove('file');
        final thumbName = row.remove('thumb');
        row.remove('id');
        if (name is! String || name.contains('/') || name.contains('\\')) continue;
        final f = File('${tmp.path}/$name');
        if (!await f.exists()) continue;
        final key = _key(row['saved_at'] as int? ?? 0, row['post_id'] as String? ?? '');
        if (have.contains(key)) {
          skipped++;
          continue;
        }
        final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1) : 'jpg';
        final dest = await SavedStore.newFile(ext);
        await f.copy(dest.path);
        String? thumb;
        if (thumbName is String && !thumbName.contains('/') && await File('${tmp.path}/$thumbName').exists()) {
          final t = await SavedStore.newFile('jpg', suffix: '_t');
          await File('${tmp.path}/$thumbName').copy(t.path);
          thumb = t.path;
        }
        await SavedStore.add(SavedItem.fromRow({...row, 'path': dest.path, 'thumb': thumb}));
        have.add(key);
        added++;
      }
      return RestoreResult(added, skipped);
    } finally {
      await tmp.delete(recursive: true);
    }
  }
}
