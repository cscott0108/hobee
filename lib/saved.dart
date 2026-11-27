import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'db.dart';
import 'models.dart';
import 'space.dart';
import 'video_poster.dart';

/// One file in the private Hobees gallery (Phase 6). The file lives in app-private storage, so the
/// phone's gallery and other apps can't see it; the row keeps where it came from.
class SavedItem {
  final int? id;
  final String path, kind; // kind: image | video
  final String? thumb; // small picture for the grid (videos); images use the file itself
  final int? width, height;
  final double? duration;
  final String postId, title, subreddit, author, permalink;
  final int created; // the post's date, epoch seconds
  final int? profile; // Following list it was saved from
  final int savedAt; // epoch ms
  const SavedItem({
    this.id, required this.path, required this.kind, this.thumb, this.width, this.height, this.duration,
    this.postId = '', this.title = '', this.subreddit = '', this.author = '', this.permalink = '',
    this.created = 0, this.profile, required this.savedAt,
  });

  bool get isVideo => kind == 'video';
  String get ext => path.contains('.') ? path.substring(path.lastIndexOf('.') + 1).toLowerCase() : (isVideo ? 'mp4' : 'jpg');

  /// The viewer's media item: the local file, with the grid thumbnail as placeholder.
  MediaItem get media => MediaItem(isVideo ? MediaType.video : MediaType.image, path, thumb ?? (isVideo ? '' : path),
      width: width, height: height, duration: duration);

  /// A post wrapper so the shared viewer can show the user / subreddit chips and the date.
  Post get post => Post(postId, title, subreddit, author, permalink, created, [media], const {});

  Map<String, Object?> toRow() => {
        'path': path, 'thumb': thumb, 'kind': kind, 'width': width, 'height': height, 'duration': duration,
        'post_id': postId, 'title': title, 'subreddit': subreddit, 'author': author, 'permalink': permalink,
        'created': created, 'profile': profile, 'saved_at': savedAt,
      };

  static SavedItem fromRow(Map<String, Object?> r) => SavedItem(
        id: r['id'] as int?, path: r['path'] as String, kind: r['kind'] as String? ?? 'image', thumb: r['thumb'] as String?,
        width: r['width'] as int?, height: r['height'] as int?, duration: (r['duration'] as num?)?.toDouble(),
        postId: r['post_id'] as String? ?? '', title: r['title'] as String? ?? '', subreddit: r['subreddit'] as String? ?? '',
        author: r['author'] as String? ?? '', permalink: r['permalink'] as String? ?? '', created: r['created'] as int? ?? 0,
        profile: r['profile'] as int?, savedAt: r['saved_at'] as int? ?? 0,
      );
}

/// Where downloads go: the private Hobees gallery (default) or the phone's gallery (Pictures / Movies).
enum SaveTo { hobees, phone }

final saveTo = ValueNotifier<SaveTo>(SaveTo.hobees);

/// True for a file path on the phone (saved gallery items) rather than a web address.
bool isLocalPath(String u) => u.startsWith('/');

String mimeFor(String ext) => switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      _ => 'image/jpeg',
    };

/// The private gallery's files and rows.
class SavedStore {
  /// Test seam: where the gallery folder lives (app-private documents by default).
  static Future<Directory> Function() baseDir = getApplicationDocumentsDirectory;

  /// Bumped on every change, so open gallery screens and the settings count reload.
  static final changes = ValueNotifier<int>(0);

  static Future<Directory> dir() async {
    final d = Directory('${(await baseDir()).path}/${Space.galleryDir}');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static int _seq = 0;

  /// A fresh file name in the gallery folder; it never names the source.
  static Future<File> newFile(String ext, {String suffix = ''}) async {
    final d = await dir();
    final ts = DateTime.now().millisecondsSinceEpoch;
    return File('${d.path}/${ts}_${_seq++}$suffix.$ext');
  }

  static Future<int> add(SavedItem it) async {
    final id = await (await Db.db).insert('saved', it.toRow());
    changes.value++;
    return id;
  }

  /// Everything, newest saved first.
  static Future<List<SavedItem>> all() async {
    final rows = await (await Db.db).query('saved', orderBy: 'saved_at DESC, id DESC');
    return rows.map(SavedItem.fromRow).toList();
  }

  static Future<int> count() async {
    final r = await (await Db.db).rawQuery('SELECT COUNT(*) AS n FROM saved');
    return r.first['n'] as int? ?? 0;
  }

  /// Test seam: one JPEG frame from a video file on the phone.
  static Future<Uint8List?> Function(String path) videoFrame = (p) => VideoPoster.frame(p);

  static final _making = <int>{};

  /// A saved video with no working grid picture (its post had none, or it was dead when downloaded): take a
  /// frame from the saved file itself and keep it as the thumbnail. Once per item per session; null if it can't.
  static Future<String?> makeThumb(SavedItem it) async {
    final id = it.id;
    if (id == null || !it.isVideo || !_making.add(id)) return null;
    try {
      final jpg = await videoFrame(it.path);
      if (jpg == null || jpg.isEmpty) return null;
      final t = await newFile('jpg', suffix: '_t');
      await t.writeAsBytes(jpg, flush: true);
      await (await Db.db).update('saved', {'thumb': t.path}, where: 'id=?', whereArgs: [id]);
      final old = it.thumb;
      if (old != null && old != t.path && isLocalPath(old)) {
        try {
          await File(old).delete();
        } catch (_) {}
      }
      changes.value++;
      return t.path;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void debugResetThumbs() => _making.clear();

  /// Remembers a picture's size (measured from the file), so its tile keeps its shape. No reload.
  static Future<void> setSize(int id, int w, int h) async =>
      (await Db.db).update('saved', {'width': w, 'height': h}, where: 'id=?', whereArgs: [id]);

  /// Width and height read from a picture file's header (no full decode), or null if it can't be read.
  static Future<(int, int)?> imageSize(String path) async {
    try {
      final buf = await ui.ImmutableBuffer.fromFilePath(path);
      final d = await ui.ImageDescriptor.encoded(buf);
      final r = (d.width, d.height);
      d.dispose();
      buf.dispose();
      return r.$1 > 0 && r.$2 > 0 ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// Deletes the files and their rows.
  static Future<void> remove(Iterable<SavedItem> items) async {
    final d = await Db.db;
    for (final it in items) {
      for (final p in {it.path, ?it.thumb}) {
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      if (it.id != null) await d.delete('saved', where: 'id=?', whereArgs: [it.id]);
    }
    changes.value++;
  }
}
