import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'db.dart';
import 'models.dart';

/// Which media you've downloaded (to the Hobees gallery or the phone's gallery), so grids and the viewer can
/// mark them. Kept by media URL. Downloads from before this existed aren't known.
class Downloaded {
  static final urls = ValueNotifier<Set<String>>(const {});

  static bool has(String url) => urls.value.contains(url);

  static Future<void> load() async {
    final rows = await (await Db.db).query('downloads', columns: ['url']);
    urls.value = {for (final r in rows) r['url'] as String};
  }

  /// Records a download. With [post], [hash], [thumb] and [savedPath] it also remembers what it looked like and
  /// where it went, for the duplicate check on later downloads.
  static Future<void> mark(String url, String postId, {Post? post, int? hash, String? thumb, String? savedPath}) async {
    if (url.isEmpty) return;
    if (!has(url)) urls.value = {...urls.value, url};
    await (await Db.db).insert('downloads', {
      'url': url, 'post_id': postId, 'at': DateTime.now().millisecondsSinceEpoch,
      'hash': hash, 'thumb': thumb, 'saved_path': savedPath,
      if (post != null) ...{'title': post.title, 'subreddit': post.subreddit, 'author': post.author, 'created': post.created},
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
