import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'archive.dart' show isRemoved, MediaCheck;
import 'db.dart';
import 'models.dart';

/// Posts Reddit marks removed (author or text [deleted] / [removed]) whose media the host refused or deleted
/// (401/403/404/410). The post itself still exists, so it moves to the text posts with a "media removed" note
/// instead of a broken tile. Only removed posts count: a live post's 403 may just be a blocked host.
class RemovedMedia {
  static final _ids = <String>{};

  /// Bumps (at most a few times a second) when posts move to text, so the grid refilters.
  static final version = ValueNotifier<int>(0);
  static Timer? _bump;

  static bool has(String id) => _ids.contains(id);

  static Future<void> load() async {
    final rows = await (await Db.db).query('media_gone', columns: ['id']);
    _ids
      ..clear()
      ..addAll([for (final r in rows) r['id'] as String]);
  }

  /// [p]'s media failed with a refused / deleted answer everywhere. Moves it to text if Reddit marks it removed.
  static void refused(Post p) {
    if (!isRemoved(p) || !_ids.add(p.id)) return;
    unawaited(Db.db.then((d) => d.insert('media_gone', {'id': p.id, 'at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace)).catchError((_) => 0));
    _bump ??= Timer(const Duration(milliseconds: 400), () {
      _bump = null;
      version.value++;
    });
  }

  /// Every link of [p]'s media answered [code] (403 refused, 404/410 deleted): a removed post moves to text,
  /// any other post counts as gone ('Hide gone images') only when deleted, since a 403 can be a blocked host.
  static void dead(Post p, int code) {
    if (isRemoved(p)) {
      refused(p);
    } else if (code == 404 || code == 410) {
      MediaCheck.markGone(p.id);
    }
  }

  /// [p] as the lists show it: without media when that's gone.
  static Post shown(Post p) =>
      p.media.isEmpty || !_ids.contains(p.id) ? p : Post(p.id, p.title, p.subreddit, p.author, p.permalink, p.created, const [], p.raw);

  @visibleForTesting
  static void debugReset() {
    _ids.clear();
    _bump?.cancel();
    _bump = null;
  }
}
