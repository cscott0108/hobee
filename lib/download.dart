import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'clean.dart';
import 'clean_image.dart';
import 'embeds.dart';
import 'models.dart';
import 'saved.dart';
import 'db.dart';
import 'download_dupes.dart';
import 'downloaded.dart';
import 'archive.dart' show MediaCheck;

const _ch = MethodChannel('hobee/media');

/// The host says the media was removed (404/410, or a redirect to a "removed" picture such as imgur's).
class MediaRemoved implements Exception {
  @override
  String toString() => 'This was removed from its host';
}

class Downloader {
  /// Media links being downloaded right now (the viewer's download button spins for these).
  static final active = ValueNotifier<Set<String>>(const {});
  static void _setActive(String url, bool on) =>
      active.value = on ? {...active.value, url} : ({...active.value}..remove(url));

  /// Shows all of [urls] as downloading now (a "download all" queue), before each one's turn.
  static void queue(Iterable<String> urls) => active.value = {...active.value, ...urls};

  /// Runs [job] with [url] shown as downloading until it ends, either way.
  static Future<T> tracking<T>(String url, Future<T> Function() job) async {
    _setActive(url, true);
    try {
      return await job();
    } finally {
      _setActive(url, false);
    }
  }

  // Test seams.
  @visibleForTesting
  static http.Client Function() client = http.Client.new;
  @visibleForTesting
  static Future<Directory> Function() tempDir = getTemporaryDirectory;

  /// Redirects are followed by hand, like the grid's "is it gone?" check, so a host's "removed" placeholder
  /// picture is never saved as if it were the real one.
  static Future<File> _fetch(String url, String name) async {
    final dir = await tempDir();
    final f = File('${dir.path}/$name');
    final c = client();
    try {
      var u = Uri.parse(url);
      for (var hop = 0; hop < 6; hop++) {
        final rq = http.Request('GET', u)
          ..followRedirects = false
          ..headers['User-Agent'] = 'android:io.github.cscott0108.hobees:v1.0';
        final r = await c.send(rq).timeout(const Duration(seconds: 60));
        final loc = r.headers['location'];
        if (MediaCheck.verdict(u, r.statusCode, loc) == false) {
          r.stream.listen(null).cancel().ignore();
          throw MediaRemoved();
        }
        if (r.statusCode >= 300 && r.statusCode < 400 && loc != null) {
          r.stream.listen(null).cancel().ignore();
          u = u.resolve(loc);
          continue;
        }
        if (r.statusCode != 200) {
          r.stream.listen(null).cancel().ignore();
          throw Exception('HTTP ${r.statusCode}');
        }
        await f.writeAsBytes(await r.stream.toBytes());
        return f;
      }
      throw Exception('Too many redirects');
    } finally {
      c.close();
    }
  }

  @visibleForTesting
  static Future<(File, String, String, bool)> prepare(MediaItem m) => _prepare(m);

  /// When the picture itself was removed: saves the thumbnail you saw in the grid instead (smaller, lower
  /// quality). The original is marked downloaded too.
  static Future<String> saveThumb(MediaItem m, Post post, {int? profile}) async {
    if (!m.thumb.startsWith('http')) throw MediaRemoved();
    final r = await save(MediaItem(MediaType.image, m.thumb, m.thumb), post, profile: profile);
    await Downloaded.mark(m.url, post.id);
    return r;
  }

  /// Storage permission for saving to shared folders (only asked on Android 9 and older).
  static Future<void> askStorage() => _perm();

  static Future<void> _perm() async {
    if (Platform.isAndroid) {
      final info = await _ch.invokeMethod<int>('sdk').catchError((_) => 99);
      if ((info ?? 99) <= 28) await Permission.storage.request();
    }
  }

  static String _ext(String url, String def) {
    final m = RegExp(r'\.(jpe?g|png|gif|webp|mp4)(\?|$)', caseSensitive: false).firstMatch(url);
    return m != null ? m.group(1)!.toLowerCase() : def;
  }

  static String _mime(String ext) => switch (ext) {
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'mp4' => 'video/mp4',
        _ => 'image/jpeg',
      };

  /// Writes a metadata-free copy next to [f] when Clean downloads is on.
  static Future<File> _clean(File f) async {
    if (!cleanDownloads.value) return f;
    final b = await f.readAsBytes();
    final c = stripMetadata(b);
    if (identical(c, b)) return f;
    final o = File('${f.path}.clean');
    await o.writeAsBytes(c);
    return o;
  }

  /// Downloads one media item and saves it where Settings → Save to says: the private Hobees gallery
  /// (default) or the phone's Pictures / Movies with a plain timestamp name. Nothing names the source.
  static Future<String> save(MediaItem m, Post post, {int? profile}) async {
    final (file, ext, mime, video) = await _prepare(m);
    final r = await store(file, ext: ext, mime: mime, video: video, item: m, post: post, profile: profile);
    // Remember what it looked like, so a later download of the same picture can be flagged.
    int? hash;
    try {
      hash = m.thumb.isEmpty ? null : await DownloadDupes.hashOf(m.thumb);
    } catch (_) {}
    final saved = saveTo.value == SaveTo.hobees ? r : null;
    if (saved != null && hash != null) {
      await (await Db.db).update('saved', {'hash': hash}, where: 'path=?', whereArgs: [saved]);
    }
    await Downloaded.mark(m.url, post.id, post: post, hash: hash, thumb: m.thumb.isEmpty ? null : m.thumb, savedPath: saved);
    return r;
  }

  /// Puts a downloaded, cleaned file in its destination. Returns the saved path or MediaStore uri.
  static Future<String> store(File f,
      {required String ext, required String mime, required bool video, required MediaItem item, required Post post, int? profile}) async {
    if (saveTo.value == SaveTo.phone) {
      await _perm();
      final name = timestampName(DateTime.now(), ext);
      final r = await _ch.invokeMethod<String>('save', {'path': f.path, 'name': name, 'mime': mime, 'video': video});
      return r ?? name;
    }
    final dest = await SavedStore.newFile(ext);
    await f.copy(dest.path);
    String? thumb;
    if (video && item.thumb.startsWith('http')) {
      // A small still for the gallery grid; the video plays from its own file.
      try {
        final r = await http.get(Uri.parse(item.thumb), headers: {'User-Agent': 'android:io.github.cscott0108.hobees:v1.0'}).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200) {
          final t = await SavedStore.newFile('jpg', suffix: '_t');
          await t.writeAsBytes(stripMetadata(r.bodyBytes));
          thumb = t.path;
        }
      } catch (_) {}
    }
    if (video && thumb == null) {
      // No working web thumbnail (none saved, or already dead): a frame from the saved file itself.
      try {
        final jpg = await SavedStore.videoFrame(dest.path);
        if (jpg != null && jpg.isNotEmpty) {
          final t = await SavedStore.newFile('jpg', suffix: '_t');
          await t.writeAsBytes(jpg, flush: true);
          thumb = t.path;
        }
      } catch (_) {}
    }
    await SavedStore.add(SavedItem(
      path: dest.path, kind: video ? 'video' : 'image', thumb: thumb, width: item.width, height: item.height, duration: item.duration,
      postId: post.id, title: post.title, subreddit: post.subreddit, author: post.author, permalink: post.permalink,
      created: post.created, profile: profile, savedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    return dest.path;
  }

  /// Downloads (and for pictures cleans) one media item into a temp file: (file, ext, mime, isVideo).
  static Future<(File, String, String, bool)> _prepare(MediaItem m) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    if (m.type == MediaType.video) {
      final best = m.redditVideo ? await _bestDash(m.url) : null;
      File video;
      var src = m.url;
      if (Embeds.needsResolve(src)) {
        try {
          src = await Embeds.playable(src);
        } catch (_) {
          if (m.preview == null) rethrow;
          src = m.preview!;
        }
      }
      try {
        video = await _fetch(best ?? src, 'v_$ts.mp4');
      } catch (_) {
        if (best == null) rethrow;
        video = await _fetch(src, 'v_$ts.mp4');
      }
      File out = video;
      if (m.redditVideo) {
        final audio = await _redditAudio(m.url, ts);
        if (audio != null) {
          final merged = File('${video.parent.path}/m_$ts.mp4');
          try {
            await _ch.invokeMethod('mux', {'video': video.path, 'audio': audio.path, 'out': merged.path});
            out = merged;
          } catch (_) {
            out = video; // fallback: video without audio
          }
        }
      }
      return (out, 'mp4', 'video/mp4', true);
    } else {
      // Original upload first (Settings → Original quality), then the preview copy if the original fails.
      var src = m.full;
      File f;
      try {
        f = await _fetch(src, 'i_$ts.${_ext(src, 'jpg')}');
      } catch (first) {
        final alt = m.preview != null && m.preview != src ? m.preview! : (m.url != src ? m.url : null);
        if (alt == null) rethrow;
        src = alt;
        try {
          f = await _fetch(src, 'i_$ts.${_ext(src, 'jpg')}');
        } catch (second) {
          // Removed at the first copy and not served by the other either: say removed (the viewer offers the
          // thumbnail then), not a bare HTTP error.
          if (first is MediaRemoved && second is! MediaRemoved) throw first;
          rethrow;
        }
      }
      var ext = _ext(src, 'jpg');
      // Cleaned copy (default): JPEG compression cleaned up, saved as PNG so nothing gets recompressed again.
      // Too big or not a JPEG: the original file as is.
      if (cleanJpegs.value && !saveOriginalBytes.value) {
        final b = await f.readAsBytes();
        if (isJpeg(b)) {
          final png = await compute(cleanPng, b);
          if (png != null) {
            f = File('${f.path}.png');
            await f.writeAsBytes(png);
            ext = 'png';
          }
        }
      }
      if (ext == 'jpeg') ext = 'jpg';
      f = await _clean(f);
      return (f, ext, _mime(ext), false);
    }
  }

  /// Saves a file that's already on the phone (upscaled PNG) to Pictures, cleaned like any download.
  static Future<String> saveFile(String path, String ext, String mime) async {
    await _perm();
    final name = timestampName(DateTime.now(), ext);
    path = (await _clean(File(path))).path;
    final r = await _ch.invokeMethod<String>('save', {'path': path, 'name': name, 'mime': mime, 'video': false});
    return r ?? name;
  }

  /// Fetches image bytes for the upscaler: the original first, then the preview copy.
  static Future<Uint8List> imageBytes(MediaItem m) async {
    Object? err;
    // Always the original upload first, even with Original quality off: the preview is resized and recompressed.
    for (final u in {m.url, ?m.preview}) {
      if (!u.startsWith('http')) continue;
      try {
        final r = await http.get(Uri.parse(u), headers: {'User-Agent': 'android:io.github.cscott0108.hobees:v1.0'}).timeout(const Duration(seconds: 60));
        if (r.statusCode == 200 && r.bodyBytes.length > 2048) return r.bodyBytes;
        err = Exception('HTTP ${r.statusCode}');
      } catch (e) {
        err = e;
      }
    }
    throw err ?? Exception('No image to upscale');
  }

  /// Highest-bandwidth video representation from v.redd.it's DASHPlaylist.mpd (fallback_url is not always the top one).
  static Future<String?> _bestDash(String fallbackUrl) async {
    final base = fallbackUrl.split('?').first.replaceAll(RegExp(r'/[^/]*$'), '');
    try {
      final r = await http.get(Uri.parse('$base/DASHPlaylist.mpd')).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      return bestDashVideo(r.body, base);
    } catch (_) {
      return null;
    }
  }

  /// Reddit serves audio separately. Try DASHPlaylist.mpd first, then known file names.
  static Future<File?> _redditAudio(String fallbackUrl, int ts) async {
    final base = fallbackUrl.split('?').first.replaceAll(RegExp(r'/[^/]*$'), '');
    final cands = <String>[];
    try {
      final r = await http.get(Uri.parse('$base/DASHPlaylist.mpd')).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final adapt = RegExp(r'<AdaptationSet[^>]*contentType="audio"[\s\S]*?</AdaptationSet>').firstMatch(r.body)?.group(0) ??
            RegExp(r'<AdaptationSet[^>]*mimeType="audio[\s\S]*?</AdaptationSet>').firstMatch(r.body)?.group(0);
        if (adapt != null) {
          final urls = RegExp(r'<BaseURL>([^<]+)</BaseURL>').allMatches(adapt).map((e) => e.group(1)!).toList();
          cands.addAll(urls.reversed.map((u) => u.startsWith('http') ? u : '$base/$u'));
        }
      }
    } catch (_) {}
    cands.addAll(['$base/DASH_AUDIO_128.mp4', '$base/DASH_AUDIO_64.mp4', '$base/DASH_audio.mp4', '$base/audio']);
    for (final c in cands) {
      try {
        return await _fetch(c, 'a_$ts.mp4');
      } catch (_) {}
    }
    return null;
  }
}

/// Picks the highest-bandwidth video BaseURL from a DASH manifest.
String? bestDashVideo(String mpd, String base) {
  String? best;
  var bw = -1;
  for (final set in RegExp(r'<AdaptationSet[\s\S]*?</AdaptationSet>').allMatches(mpd)) {
    final a = set.group(0)!;
    if (a.contains('audio')) continue;
    for (final rep in RegExp(r'<Representation[^>]*bandwidth="(\d+)"[\s\S]*?<BaseURL>([^<]+)</BaseURL>').allMatches(a)) {
      final b = int.parse(rep.group(1)!);
      if (b > bw) { bw = b; final u = rep.group(2)!; best = u.startsWith('http') ? u : '$base/$u'; }
    }
  }
  return best;
}
