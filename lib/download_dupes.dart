import 'dart:io';
import 'package:flutter/foundation.dart';
import 'db.dart';
import 'dedupe.dart';
import 'find.dart' show exactBits, similarBits;
import 'models.dart';

/// How a new download matches an earlier one.
enum DupKind {
  /// The very same file address was downloaded before.
  same,

  /// The picture fingerprint matches (a repost of the same picture).
  exact,

  /// The fingerprints are close: probably the same picture, edited, cropped or re-encoded.
  similar,
}

/// An earlier download that a new one looks like.
class DupMatch {
  final DupKind kind;

  /// Fingerprint bits apart (0 = identical).
  final int bits;

  /// What to show for the earlier one: a local file (Hobees gallery) or a preview URL.
  final String? image;

  /// The earlier one's file in the Hobees gallery (null: it went to the phone's gallery).
  final String? savedPath;
  final String title, subreddit, author;

  /// When the earlier one was posted (seconds), if known.
  final int? created;

  const DupMatch({required this.kind, required this.bits, this.image, this.savedPath, this.title = '', this.subreddit = '', this.author = '', this.created});

  String get label => switch (kind) {
        DupKind.same => 'Already downloaded',
        DupKind.exact => 'Same picture downloaded before',
        DupKind.similar => 'Looks like one downloaded before',
      };
}

/// Compares a download about to start with what was downloaded before.
class DownloadDupes {
  /// Test seam: a picture's fingerprint from its preview URL (the grid has usually made it already).
  static Future<int?> Function(String url) hashOf = (u) => Dedupe.hashFor(u);

  /// Test seam: a fingerprint from a file's bytes.
  static Future<int?> Function(Uint8List bytes) hashBytes = (b) => compute(dHash, b);

  /// The earlier download [m] most looks like, or null. Earlier downloads removed from the Hobees gallery
  /// since don't count (you deleted them on purpose).
  static Future<DupMatch?> find(MediaItem m) async {
    if (m.url.isEmpty || m.url.startsWith('/')) return null;
    final d = await Db.db;
    final rows = await d.rawQuery('SELECT d.url, d.hash, d.thumb, d.title, d.subreddit, d.author, d.created, d.saved_path, '
        's.id AS sid, s.kind AS skind, s.thumb AS sthumb FROM downloads d LEFT JOIN saved s ON s.path = d.saved_path');
    bool removed(Map<String, Object?> r) => r['saved_path'] != null && r['sid'] == null;
    for (final r in rows) {
      if (r['url'] == m.url && !removed(r)) return _match(r, DupKind.same, 0);
    }
    int? h;
    try {
      h = m.thumb.isEmpty ? null : await hashOf(m.thumb);
    } catch (_) {}
    if (h == null) return null;
    Map<String, Object?>? best;
    var bestBits = similarBits + 1;
    for (final r in rows) {
      final x = r['hash'] as int?;
      if (x == null || removed(r)) continue;
      final b = Dedupe.hamming(h, x);
      if (b < bestBits) { best = r; bestBits = b; }
    }
    // Hobees gallery files saved before downloads remembered their fingerprint.
    final known = {for (final r in rows) ?r['saved_path']};
    for (final s in await d.rawQuery('SELECT id, path, kind, thumb, hash, title, subreddit, author, created FROM saved WHERE hash IS NOT NULL')) {
      if (known.contains(s['path'])) continue;
      final b = Dedupe.hamming(h, s['hash'] as int);
      if (b < bestBits) {
        best = {...s, 'saved_path': s['path'], 'sid': s['id'], 'skind': s['kind'], 'sthumb': s['thumb'], 'thumb': null};
        bestBits = b;
      }
    }
    if (best == null) return null;
    return _match(best, bestBits <= exactBits ? DupKind.exact : DupKind.similar, bestBits);
  }

  static DupMatch _match(Map<String, Object?> r, DupKind kind, int bits) {
    final saved = r['sid'] != null ? r['saved_path'] as String? : null;
    // A gallery picture shows its own file; a gallery video its still; otherwise the preview it was downloaded from.
    final image = saved != null ? (r['skind'] == 'video' ? r['sthumb'] as String? : saved) : r['thumb'] as String?;
    return DupMatch(
      kind: kind, bits: bits, image: image ?? r['thumb'] as String?, savedPath: saved,
      title: r['title'] as String? ?? '', subreddit: r['subreddit'] as String? ?? '', author: r['author'] as String? ?? '',
      created: r['created'] as int?,
    );
  }

  /// Gives Hobees gallery files saved before this update their fingerprint (pictures from the file, videos from
  /// their still), a few at a time. Unreadable ones are left for later. Returns how many were filled in.
  static Future<int> fillGallery({int maxBytes = 40 << 20}) async {
    final d = await Db.db;
    var n = 0;
    for (final s in await d.query('saved', columns: ['id', 'path', 'kind', 'thumb'], where: 'hash IS NULL')) {
      final path = s['kind'] == 'video' ? s['thumb'] as String? : s['path'] as String?;
      if (path == null) continue;
      try {
        final f = File(path);
        if (!await f.exists() || await f.length() > maxBytes) continue;
        final h = await hashBytes(await f.readAsBytes());
        if (h == null) continue;
        await d.update('saved', {'hash': h}, where: 'id=?', whereArgs: [s['id']]);
        n++;
      } catch (_) {}
    }
    return n;
  }
}
