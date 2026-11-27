import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'models.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'space.dart';

/// (rowid, post) for each readable row; unreadable JSON is skipped.
List<(int, Post)> _decodeRows(List<(int, String)> rows) => [
      for (final (r, j) in rows)
        if (_tryPost(j) case final p?) (r, p)
    ];

Post? _tryPost(String j) {
  try {
    return Post.fromJson(jsonDecode(j));
  } catch (_) {
    return null;
  }
}

List<Post> _decodeAll(List<String> js) => js.map((j) => Post.fromJson(jsonDecode(j))).whereType<Post>().toList();

/// (rowid, user, subreddit) in lower case for each saved post's JSON; '' when missing or unreadable.
List<(int, String, String)> _channelsOf(List<(int, String)> rows) => [
      for (final (r, j) in rows)
        () {
          try {
            final m = jsonDecode(j);
            String s(Object? o) => o is String ? o.toLowerCase() : '';
            return m is Map ? (r, s(m['author']), s(m['subreddit'])) : (r, '', '');
          } catch (_) {
            return (r, '', '');
          }
        }(),
    ];

enum WindowRead { all, window, next }

class Db {
  static Database? _db;

  /// Test seam: tests give each test process its own file (test/flutter_test_config.dart), so test files
  /// running side by side don't lock each other out of one shared database.
  static String fileName = 'hobee.db';

  /// Closes the open database, so the next use opens the current profile's file (tests).
  @visibleForTesting
  static Future<void> debugClose() async {
    final d = _db;
    _db = null;
    await d?.close();
  }

  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(p.join(await getDatabasesPath(), Space.dbFile(fileName)), version: 12, onUpgrade: (db, o, n) async {
      if (o < 2) await _v2(db);
      if (o < 3) await _v3(db);
      if (o < 4) await _v4(db);
      if (o < 5) await _v5(db);
      if (o < 6) await _v6(db);
      if (o < 7) await _v7(db);
      if (o < 8) await _v8(db);
      if (o < 9) await _v9(db);
      if (o < 10) await _v10(db);
      if (o < 11) await _v11(db);
      if (o < 12) await _v12(db);
    }, onCreate: (db, v) async {
      await db.execute('CREATE TABLE posts(source TEXT, id TEXT, created INTEGER, json TEXT, PRIMARY KEY(source,id))');
      await db.execute('CREATE INDEX idx_src_created ON posts(source, created)');
      await db.execute('CREATE TABLE cursors(source TEXT PRIMARY KEY, after TEXT, done INTEGER)');
      await _v2(db);
      await _v3(db);
      await _v4(db);
      await _v5(db);
      await _v6(db);
      await _v8(db);
      await _v9(db);
      await _v10(db);
      await _v11(db);
      await _v12(db);
    });
    return _db!;
  }

  /// v12: the archive pace log (see PaceLog): one row per archive request or marker, newest 5,000 kept.
  static Future<void> _v12(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS pace_log(id INTEGER PRIMARY KEY AUTOINCREMENT, t INTEGER, host TEXT, caller TEXT, '
        'kind TEXT, fg INTEGER, inflight INTEGER, gap_ms INTEGER, queue_ms INTEGER, reply_ms INTEGER, status INTEGER, result TEXT, '
        'rows INTEGER, reset_s INTEGER, net TEXT, note TEXT)');
  }

  /// v11: what each download looked like (picture fingerprint, preview and where it came from), so a new
  /// download can be compared with earlier ones; and fingerprints for the Hobees gallery's files.
  static Future<void> _v11(Database db) async {
    Future<void> add(String table, String col, String type) async {
      final cols = {for (final r in await db.rawQuery('PRAGMA table_info($table)')) r['name']};
      if (!cols.contains(col)) await db.execute('ALTER TABLE $table ADD COLUMN $col $type');
    }
    for (final (c, t) in const [('hash', 'INTEGER'), ('thumb', 'TEXT'), ('title', 'TEXT'), ('subreddit', 'TEXT'), ('author', 'TEXT'),
      ('created', 'INTEGER'), ('saved_path', 'TEXT')]) {
      await add('downloads', c, t);
    }
    await add('saved', 'hash', 'INTEGER');
  }

  /// v10: each post's user and subreddit (lower case) in their own indexed columns, so one channel's saved
  /// posts are found without reading every post. Older rows are filled in by [backfillChannels].
  static Future<void> _v10(Database db) async {
    final cols = {for (final r in await db.rawQuery('PRAGMA table_info(posts)')) r['name']};
    if (!cols.contains('author')) await db.execute('ALTER TABLE posts ADD COLUMN author TEXT');
    if (!cols.contains('sub')) await db.execute('ALTER TABLE posts ADD COLUMN sub TEXT');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_posts_author ON posts(author, source)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_posts_sub ON posts(sub, source)');
  }

  /// True once every saved post has its user and subreddit columns (new installs at once, upgrades after
  /// [backfillChannels]). Until then channel lookups fall back to scanning.
  static bool channelsReady = false;

  /// Fills the user and subreddit columns of posts saved before v10, [chunkRows] at a time, decoded off the UI
  /// thread, with a short pause between chunks so the app stays smooth. Safe to call again; stops when done.
  static Future<void> backfillChannels({Duration pause = const Duration(milliseconds: 60)}) async {
    final d = await db;
    while (true) {
      final rows = await d.rawQuery('SELECT rowid AS r, json FROM posts WHERE author IS NULL LIMIT ?', [chunkRows]);
      if (rows.isEmpty) break;
      final raw = [for (final r in rows) (r['r'] as int, r['json'] as String)];
      final names = raw.length > 150 ? await compute(_channelsOf, raw) : _channelsOf(raw);
      final b = d.batch();
      for (final (rowid, author, sub) in names) {
        b.rawUpdate('UPDATE posts SET author=?, sub=? WHERE rowid=?', [author, sub, rowid]);
      }
      await b.commit(noResult: true);
      if (rows.length < chunkRows) break;
      await Future<void>.delayed(pause);
    }
    channelsReady = true;
  }

  /// Posts saved in any Following list by [author] (and in [sub], when given), or in subreddit [sub]; each
  /// post once, newest first. Empty until [channelsReady].
  static Future<List<Post>> followedChannel({String? author, String? sub}) async {
    if (!channelsReady || (author == null && sub == null)) return const [];
    final w = <String>["source LIKE 'fol:%'"];
    final args = <Object?>[];
    if (author != null) { w.insert(0, 'author=?'); args.insert(0, author.toLowerCase()); }
    if (sub != null) { w.insert(author == null ? 0 : 1, 'sub=?'); args.insert(author == null ? 0 : 1, sub.toLowerCase()); }
    return _loadChunked(w.join(' AND '), args, onePerId: true);
  }

  /// v9: media you downloaded (marked in grids and the viewer).
  static Future<void> _v9(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS downloads(url TEXT PRIMARY KEY, post_id TEXT, at INTEGER)');
  }

  /// v8: the private Hobees gallery (Phase 6): one row per saved file.
  static Future<void> _v8(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS saved(id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT, thumb TEXT, kind TEXT, '
        'width INTEGER, height INTEGER, duration REAL, post_id TEXT, title TEXT, subreddit TEXT, author TEXT, permalink TEXT, '
        'created INTEGER, profile INTEGER, saved_at INTEGER)');
  }

  /// v7: Following posts saved before trimming: drop the fields the app never reads (see [slimPost]).
  static Future<void> _v7(Database db) async {
    var last = 0;
    while (true) {
      final rows = await db.rawQuery("SELECT rowid AS r, json FROM posts WHERE source LIKE 'fol:%' AND rowid > ? ORDER BY rowid LIMIT 500", [last]);
      if (rows.isEmpty) break;
      last = rows.last['r'] as int;
      final b = db.batch();
      for (final r in rows) {
        try {
          final slim = jsonEncode(slimPost(jsonDecode(r['json'] as String) as Map<String, dynamic>));
          b.rawUpdate('UPDATE posts SET json=? WHERE rowid=?', [slim, r['r']]);
        } catch (_) {}
      }
      await b.commit(noResult: true);
    }
  }

  /// v6: local profiles and the subreddits/users each one follows (Following feed, no login).
  static Future<void> _v6(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS profiles(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE COLLATE NOCASE, created INTEGER)');
    await db.execute('CREATE TABLE IF NOT EXISTS follows(profile INTEGER, kind TEXT, name TEXT COLLATE NOCASE, added INTEGER, PRIMARY KEY(profile, kind, name))');
  }

  static Future<void> _v2(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS media_check(url TEXT PRIMARY KEY, result TEXT, checked INTEGER)');
  }

  static Future<void> _v3(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS phash(url TEXT PRIMARY KEY, hash INTEGER)');
  }

  static Future<void> _v4(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS deep_history(key TEXT PRIMARY KEY, avatar TEXT, posts INTEGER, last INTEGER, seconds INTEGER DEFAULT 0)');
    await db.execute('CREATE TABLE IF NOT EXISTS interest(kind TEXT, key TEXT, score REAL, updated INTEGER, PRIMARY KEY(kind, key))');
    await db.execute('CREATE TABLE IF NOT EXISTS sub_authors(sub TEXT, author TEXT, n INTEGER, fetched INTEGER, PRIMARY KEY(sub, author))');
  }

  static Future<void> _v5(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS acct_meta(author TEXT PRIMARY KEY, post INTEGER, comment INTEGER, total INTEGER, nsfw INTEGER, fetched INTEGER)');
    await db.execute('CREATE TABLE IF NOT EXISTS author_mix(author TEXT, sub TEXT, n INTEGER, img INTEGER, vid INTEGER, gal INTEGER, txt INTEGER, nsfw INTEGER, titles TEXT, fetched INTEGER, PRIMARY KEY(author, sub))');
    await db.execute('CREATE TABLE IF NOT EXISTS sub_meta(sub TEXT PRIMARY KEY, nsfw REAL, fetched INTEGER)');
  }

  /// Removes from a Following list's saved feed the posts of one subreddit ([byAuthor] false) or one user
  /// ([byAuthor] true), after it was unfollowed. Posts that still belong to the list through another follow
  /// ([keep] says so) stay. Returns how many were removed.
  static Future<int> dropPostsOf(String source, String name, {required bool byAuthor, bool Function(Post p)? keep}) async {
    final d = await db;
    final key = byAuthor ? 'author' : 'subreddit';
    final want = name.toLowerCase();
    var last = 0, removed = 0;
    while (true) {
      // Indexed column once filled in; before that a cheap text match (the saved JSON has no spaces). Either
      // way the real field is checked below, case-insensitive.
      final rows = channelsReady
          ? await d.rawQuery('SELECT rowid AS r, id, json FROM posts WHERE ${byAuthor ? 'author' : 'sub'}=? AND source=? AND rowid > ? '
              'ORDER BY rowid LIMIT ?', [want, source, last, chunkRows])
          : await d.rawQuery(
              'SELECT rowid AS r, id, json FROM posts WHERE source=? AND rowid > ? AND instr(lower(json), ?) > 0 ORDER BY rowid LIMIT ?',
              [source, last, '"$key":"$want"', chunkRows]);
      if (rows.isEmpty) break;
      last = rows.last['r'] as int;
      final b = d.batch();
      for (final r in rows) {
        final p = Post.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>);
        if (p == null) continue;
        if ((byAuthor ? p.author : p.subreddit).toLowerCase() != want || (keep?.call(p) ?? false)) continue;
        b.delete('posts', where: 'source=? AND id=?', whereArgs: [source, r['id']]);
        removed++;
      }
      await b.commit(noResult: true);
    }
    return removed;
  }

  /// Removes every post of [source] that [keep] says no longer belongs (e.g. from follows removed before
  /// unfollowing cleaned up). Reads in chunks. Returns how many were removed.
  static Future<int> prunePosts(String source, bool Function(Post p) keep) async {
    final d = await db;
    var last = 0, removed = 0;
    while (true) {
      final rows = await d.rawQuery('SELECT rowid AS r, id, json FROM posts WHERE source=? AND rowid > ? ORDER BY rowid LIMIT ?',
          [source, last, chunkRows]);
      if (rows.isEmpty) break;
      last = rows.last['r'] as int;
      final b = d.batch();
      for (final r in rows) {
        final p = Post.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>);
        if (p == null || keep(p)) continue;
        b.delete('posts', where: 'source=? AND id=?', whereArgs: [source, r['id']]);
        removed++;
      }
      await b.commit(noResult: true);
    }
    return removed;
  }

  /// Rows per database read. One query result is copied whole across the platform channel, so a big feed
  /// read at once can run the Android side out of memory; reading it in chunks keeps each copy small.
  static int chunkRows = 1000;

  /// Posts matching [where], newest first, read [chunkRows] at a time and decoded off the UI thread.
  static Future<List<Post>> _loadChunked(String where, List<Object?> args, {bool onePerId = false}) async {
    final d = await db;
    final out = <Post>[];
    final seen = <String>{};
    var last = 0;
    while (true) {
      final rows = await d.rawQuery('SELECT rowid AS r, json FROM posts WHERE $where AND rowid > ? ORDER BY rowid LIMIT ?',
          [...args, last, chunkRows]);
      if (rows.isEmpty) break;
      last = rows.last['r'] as int;
      final raw = [for (final r in rows) r['json'] as String];
      final posts = raw.length > 150 ? await compute(_decodeAll, raw) : _decodeAll(raw);
      for (final p in posts) {
        if (!onePerId || seen.add(p.id)) out.add(p);
      }
      if (rows.length < chunkRows) break;
    }
    out.sort((a, b) => b.created.compareTo(a.created));
    return out;
  }

  /// Posts of [source] that can match a search, newest first, found by the database instead of reading the
  /// whole feed: every group in [anyOf] needs one of its words somewhere in the post (title, text, flair,
  /// subreddit, user, link), [author] and [sub] use the indexed columns, [from] / [to] (seconds) the date.
  /// The words are matched as plain lower-case text; the app still checks and ranks what comes back.
  static Future<List<Post>> loadMatching(String source, {List<List<String>> anyOf = const [], String? author, String? sub, int? from, int? to}) async =>
      (await loadMatchingCapped(source, anyOf: anyOf, author: author, sub: sub, from: from, to: to, cap: 1 << 30)).$1;

  /// Like [loadMatching], but reads at most the newest [cap] matches; the bool says whether there were more.
  /// The database picks and orders the matches first, so only the ones shown are read and decoded.
  static Future<(List<Post>, bool)> loadMatchingCapped(String source,
      {List<List<String>> anyOf = const [], String? author, String? sub, int? from, int? to, int cap = 2000}) async {
    final w = <String>['source=?'];
    final args = <Object?>[source];
    if (author != null) { w.add('author=?'); args.add(author.toLowerCase()); }
    if (sub != null) { w.add('sub=?'); args.add(sub.toLowerCase()); }
    if (from != null) { w.add('created>=?'); args.add(from); }
    if (to != null) { w.add('created<?'); args.add(to); }
    for (final g in anyOf) {
      if (g.isEmpty) continue;
      w.add('(${List.filled(g.length, 'instr(lower(json), ?) > 0').join(' OR ')})');
      args.addAll(g);
    }
    final d = await db;
    final ids = [
      for (final r in await d.rawQuery('SELECT rowid AS r FROM posts WHERE ${w.join(' AND ')} ORDER BY created DESC, id DESC LIMIT ?',
          [...args, cap + 1]))
        r['r'] as int
    ];
    final more = ids.length > cap;
    final take = more ? ids.sublist(0, cap) : ids;
    final out = <Post>[];
    for (var i = 0; i < take.length; i += chunkRows) {
      final part = take.sublist(i, i + chunkRows > take.length ? take.length : i + chunkRows);
      final rows = await d.rawQuery('SELECT json FROM posts WHERE rowid IN (${List.filled(part.length, '?').join(',')})', part);
      final raw = [for (final r in rows) r['json'] as String];
      out.addAll(raw.length > 150 ? await compute(_decodeAll, raw) : _decodeAll(raw));
    }
    out.sort((a, b) => b.created.compareTo(a.created));
    return (out, more);
  }

  /// Posts the account suggestions learn from: the newest [cap] outside the Following lists (what you viewed
  /// and searched), each once, newest first. Reading every saved post here decoded all the Following posts
  /// (160k, about 1.8 GB) each time a user's page opened.
  static Future<List<Post>> loadForSuggestions({int cap = 5000}) async {
    final d = await db;
    final ids = [
      for (final r in await d.rawQuery("SELECT rowid AS r FROM posts WHERE source NOT LIKE 'fol:%' ORDER BY created DESC LIMIT ?",
          [cap * 2])) // the same post can be saved under several sources
        r['r'] as int
    ];
    final out = <Post>[];
    final seen = <String>{};
    for (var i = 0; i < ids.length && out.length < cap; i += chunkRows) {
      final part = ids.sublist(i, i + chunkRows > ids.length ? ids.length : i + chunkRows);
      final rows = await d.rawQuery('SELECT rowid AS r, json FROM posts WHERE rowid IN (${List.filled(part.length, '?').join(',')})', part);
      // IN returns rows in storage order: put them back newest first before the cap picks.
      final byId = {for (final r in rows) r['r'] as int: r['json'] as String};
      final raw = [for (final id in part) ?byId[id]];
      for (final p in raw.length > 150 ? await compute(_decodeAll, raw) : _decodeAll(raw)) {
        if (out.length < cap && seen.add(p.id)) out.add(p);
      }
    }
    out.sort((a, b) => b.created.compareTo(a.created));
    return out;
  }

  /// Subreddits [author] posted in, with how many posts, from the indexed columns (nothing decoded). Empty until
  /// [channelsReady].
  static Future<Map<String, int>> subsOf(String author) async {
    if (!channelsReady) return const {};
    final d = await db;
    final rows = await d.rawQuery(
        "SELECT sub, COUNT(DISTINCT id) AS n FROM posts WHERE author=? AND sub IS NOT NULL AND sub != '' GROUP BY sub",
        [author.toLowerCase()]);
    return {for (final r in rows) r['sub'] as String: r['n'] as int};
  }

  /// Every cached post once (by id), newest first. Decoded off the UI thread.
  /// Every cached post once (by id), a chunk of [chunkRows] rows at a time, with its rowid (for [postAt]).
  /// Only one chunk is held at a time, so a scan over the whole cache stays small.
  static Future<void> eachPostChunk(Future<void> Function(List<(int, Post)> chunk) f) async {
    final d = await db;
    final seen = <String>{};
    var last = 0;
    while (true) {
      final rows = await d.rawQuery('SELECT rowid AS r, json FROM posts WHERE rowid > ? ORDER BY rowid LIMIT ?', [last, chunkRows]);
      if (rows.isEmpty) break;
      last = rows.last['r'] as int;
      final raw = [for (final r in rows) (r['r'] as int, r['json'] as String)];
      final posts = raw.length > 150 ? await compute(_decodeRows, raw) : _decodeRows(raw);
      await f([for (final x in posts) if (seen.add(x.$2.id)) x]);
      if (rows.length < chunkRows) break;
    }
  }

  /// The post saved in row [rowid], or null when it's gone.
  static Future<Post?> postAt(int rowid) async {
    final rows = await (await db).rawQuery('SELECT json FROM posts WHERE rowid=?', [rowid]);
    return rows.isEmpty ? null : _tryPost(rows.first['json'] as String);
  }

  static Future<List<Post>> loadEverything() => _loadChunked('1=1', const [], onePerId: true);

  static Future<int> count(String source) async {
    final d = await db;
    return Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM posts WHERE source=?', [source])) ?? 0;
  }

  /// Perceptual hashes by thumbnail URL (null value = could not hash).
  static Future<Map<String, int?>> hashes(List<String> urls) async {
    final d = await db;
    final out = <String, int?>{};
    for (var i = 0; i < urls.length; i += 500) {
      final chunk = urls.sublist(i, i + 500 > urls.length ? urls.length : i + 500);
      final rows = await d.query('phash', where: 'url IN (${List.filled(chunk.length, '?').join(',')})', whereArgs: chunk);
      for (final r in rows) {
        out[r['url'] as String] = r['hash'] as int?;
      }
    }
    return out;
  }

  static Future<void> setHash(String url, int? hash) async {
    final d = await db;
    await d.insert('phash', {'url': url, 'hash': hash}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Cached media resolution: '' = gone, otherwise working URL. null = not checked (or stale after 14 days).
  static Future<String?> mediaStatus(String url) async {
    final d = await db;
    final r = await d.query('media_check', where: 'url=?', whereArgs: [url]);
    if (r.isEmpty) return null;
    final age = DateTime.now().millisecondsSinceEpoch - (r.first['checked'] as int);
    if (age > const Duration(days: 14).inMilliseconds) return null;
    return r.first['result'] as String?;
  }

  static Future<void> setMediaStatus(String url, String result) async {
    final d = await db;
    await d.insert('media_check', {'url': url, 'result': result, 'checked': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Set<String>> liveIds(String source) async {
    final d = await db;
    final rows = await d.rawQuery('SELECT id FROM posts WHERE source=? AND instr(json, ?) > 0', [source, '"_hobee_live":true']);
    return {for (final r in rows) r['id'] as String};
  }

  static Future<Set<String>> thinIds(String source) async {
    final d = await db;
    final rows = await d.rawQuery('SELECT id FROM posts WHERE source=? AND instr(json, ?) > 0', [source, '"_hobee_thin":true']);
    return {for (final r in rows) r['id'] as String};
  }

  static Future<void> savePosts(String source, List<Post> posts) async {
    final d = await db;
    final b = d.batch();
    for (final x in posts) {
      b.insert('posts', {'source': source, 'id': x.id, 'created': x.created, 'json': x.encode(), 'author': x.author.toLowerCase(), 'sub': x.subreddit.toLowerCase()},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
  }

  /// Posts of [source], newest first (read in chunks; big feeds are decoded off the UI thread).
  static Future<List<Post>> load(String source) => _loadChunked('source=?', [source]);

  /// Feeds with more saved posts than this open as a window: the grid loads [windowStep] of the newest posts
  /// and the next [windowStep] from the database as you scroll, instead of all of them at once.
  static int windowMin = 2000;
  static int windowStep = 1000;

  /// What the grid reads for a feed of [count] saved posts: the whole feed (small feeds, or [needAll] for a
  /// search or date range), the newest window (at least [windowStep], or as many as already [shown] when
  /// reloading the same window), or the [grow] chunk below it. Returns the kind and the row limit (0 = all).
  static (WindowRead, int) windowRead({required int count, required int shown, required bool sameWindow, required bool needAll, bool grow = false}) {
    if (count <= windowMin || needAll) return (WindowRead.all, 0);
    if (grow && sameWindow && shown > 0) return (WindowRead.next, windowStep);
    return (WindowRead.window, sameWindow && shown > windowStep ? shown : windowStep);
  }

  /// Up to [limit] posts of [source], newest first, older than the post ([created], [id]) when given.
  static Future<List<Post>> loadPage(String source, {required int limit, int? created, String? id}) async {
    final d = await db;
    final rows = created == null
        ? await d.rawQuery('SELECT json FROM posts WHERE source=? ORDER BY created DESC, id DESC LIMIT ?', [source, limit])
        : await d.rawQuery(
            'SELECT json FROM posts WHERE source=? AND (created < ? OR (created = ? AND id < ?)) ORDER BY created DESC, id DESC LIMIT ?',
            [source, created, created, id, limit]);
    final raw = [for (final r in rows) r['json'] as String];
    return raw.length > 150 ? await compute(_decodeAll, raw) : _decodeAll(raw);
  }

  static Future<(String?, bool)> cursor(String source) async {
    final d = await db;
    final r = await d.query('cursors', where: 'source=?', whereArgs: [source]);
    if (r.isEmpty) return (null, false);
    return (r.first['after'] as String?, (r.first['done'] as int) == 1);
  }

  static Future<void> setCursor(String source, String? after) async {
    final d = await db;
    await d.insert('cursors', {'source': source, 'after': after, 'done': after == null ? 1 : 0},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> clearAll() async {
    final d = await db;
    await d.delete('posts');
    await d.delete('cursors');
    await d.delete('media_check');
    await d.delete('phash');
    await d.delete('sub_authors');
  }
}

