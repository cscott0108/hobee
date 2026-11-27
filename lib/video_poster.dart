import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'dedupe.dart';
import 'embeds.dart';
import 'models.dart';
import 'net_guard.dart';
import 'player.dart' show probeStatus;
import 'space.dart';

/// A frame from the video itself, for grid tiles of videos with no working picture (the archive saved the post
/// before Reddit made a preview, or the preview was deleted). A small copy is downloaded, one frame read on the
/// phone, and the JPEG kept in the app's temporary folder (emptied when the profile switches).
class VideoPoster {
  /// Test seams.
  static Future<Uint8List?> Function(String url) fetch = (u) => Dedupe.fetchCapped(u, maxBytes, timeout: const Duration(seconds: 20));
  static Future<Uint8List?> Function(String path) frame =
      (p) => const MethodChannel('hobee/media').invokeMethod<Uint8List>('poster', {'path': p, 'width': 360}).timeout(const Duration(seconds: 20));
  static Future<Directory> Function() dir = getTemporaryDirectory;
  static Future<Uint8List?> Function(String url) frameFromUrl = (u) => const MethodChannel('hobee/media')
      .invokeMethod<Uint8List>('posterUrl', {'url': u, 'headers': {'User-Agent': Embeds.ua}, 'width': 360})
      .timeout(const Duration(seconds: 20));

  /// Videos whose tile has no working picture (it showed, or waits for, a frame), by video link.
  static final _needed = <String>{};
  static final _fromViewer = <String>{};

  /// Bumps when the viewer saved a frame, so a tile still showing the film icon picks it up.
  static final saved = ValueNotifier<int>(0);

  static void need(MediaItem m) => _needed.add(m.url);

  static Future<int?> Function(String url) probe = probeStatus;
  static final _dead = <String, Future<int?>>{};

  /// For a video with no picture and no frame: asks each of its links once. Returns 410 when they all answered
  /// deleted (404/410, or RedGIFs says it's gone), 403 when all refused, null when any works, didn't answer or
  /// there's nothing to ask. Once per video per session.
  static Future<int?> deadCode(MediaItem m) {
    if (NetGuard.paused) return Future.value();
    return _dead[m.url] ??= _check(m);
  }

  static Future<int?> _check(MediaItem m) async {
    final codes = <int?>[];
    if (Embeds.redgifsId(m.url) != null || Embeds.streamableId(m.url) != null) {
      try {
        codes.add(await probe(await Embeds.playable(m.url)));
      } catch (e) {
        codes.add('$e'.contains('Gone') ? 410 : null);
      }
    } else {
      for (final u in {m.url, ?m.hls}) {
        if (u.startsWith('http')) codes.add(await probe(u));
      }
    }
    final p = m.preview;
    if (p != null && p.startsWith('http')) codes.add(await probe(p));
    if (codes.isEmpty || codes.any((c) => !const {401, 403, 404, 410}.contains(c))) return null;
    return codes.any((c) => c == 404 || c == 410) ? 410 : 403;
  }

  /// Third way to a tile frame: [m] just started playing from [url] in the viewer. If its tile has no picture
  /// and no frame yet, read one straight from that link (streamed, not downloaded whole). Stream playlists
  /// (.m3u8) can't be read, so a Reddit video uses its plain .mp4 link instead. Once per video.
  static Future<void> fromPlaying(MediaItem m, String url, {bool hls = false}) async {
    if (!_needed.contains(m.url) || !_fromViewer.add(m.url) || NetGuard.paused) return;
    try {
      final out = await _file(m.url);
      if (await out.exists()) return;
      if (await (_done[m.url] ?? Future<File?>.value()) != null) return;
      final src = !hls ? url : (m.url.startsWith('http') && !m.url.contains('.m3u8') ? m.url : null);
      if (src == null || !src.startsWith('http')) return;
      final jpg = await frameFromUrl(src).catchError((_) => null);
      if (jpg == null || jpg.isEmpty) return;
      await out.parent.create(recursive: true);
      await out.writeAsBytes(jpg, flush: true);
      _done[m.url] = Future.value(out);
      saved.value++;
    } catch (_) {}
  }

  static const maxBytes = 8 << 20;
  static const maxRunning = 2;

  static final _done = <String, Future<File?>>{};
  static int _running = 0;
  static final _waiting = <Completer<void>>[];

  /// Addresses to read a frame from, smallest first.
  static Future<List<String>> sources(MediaItem m) async {
    final out = <String>[];
    if (Embeds.redgifsId(m.url) != null || Embeds.streamableId(m.url) != null) {
      try {
        out.add(await Embeds.smallPlayable(m.url));
      } catch (_) {}
    } else if (m.url.startsWith('http')) {
      out.addAll(Dedupe.frameSources(m.url));
    }
    final p = m.preview;
    if (p != null && p.startsWith('http')) out.addAll(Dedupe.frameSources(p));
    return out.toSet().toList();
  }

  static Future<File> _file(String url) async {
    final d = Directory('${(await dir()).path}/posters${Space.id == 0 ? '' : '_p${Space.id}'}');
    return File('${d.path}/${sha1.convert(url.codeUnits)}.jpg');
  }

  /// The saved frame for [m], making it if needed. Null when no frame could be read. [wanted] is asked before
  /// the work starts, so tiles scrolled away meanwhile cost nothing.
  static Future<File?> of(MediaItem m, {bool Function()? wanted}) {
    final key = m.url;
    final f = _done[key];
    if (f != null) return f;
    final made = _make(m, wanted);
    _done[key] = made;
    // A tile that was gone before its turn may try again later; real failures are not retried this session.
    made.then((r) {
      if (r == null && wanted != null && !wanted()) _done.remove(key);
    });
    return made;
  }

  static Future<File?> _make(MediaItem m, bool Function()? wanted) async {
    final out = await _file(m.url);
    if (await out.exists()) return out;
    if (_running >= maxRunning) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    } else {
      _running++;
    }
    try {
      if (wanted != null && !wanted()) return null;
      if (NetGuard.paused) return null;
      for (final src in await sources(m)) {
        final bytes = await fetch(src).catchError((_) => null);
        if (bytes == null) continue;
        final tmp = File('${out.parent.path}/v_${src.hashCode.toUnsigned(32)}.mp4');
        try {
          await out.parent.create(recursive: true);
          await tmp.writeAsBytes(bytes, flush: true);
          final jpg = await frame(tmp.path).catchError((_) => null);
          if (jpg != null && jpg.isNotEmpty) {
            await out.writeAsBytes(jpg, flush: true);
            return out;
          }
        } finally {
          try {
            await tmp.delete();
          } catch (_) {}
        }
      }
      return null;
    } finally {
      // Newest waiter first: that's the tile just scrolled onto the screen.
      if (_waiting.isNotEmpty) {
        _waiting.removeLast().complete();
      } else {
        _running--;
      }
    }
  }

  @visibleForTesting
  static void debugReset() {
    _done.clear();
    _needed.clear();
    _fromViewer.clear();
    _dead.clear();
    _waiting.clear();
    _running = 0;
  }
}

/// A video tile's frame from [VideoPoster], or the film icon while it loads or when there is none.
class VideoPosterImage extends StatefulWidget {
  final MediaItem item;
  final int cacheWidth;
  final BoxFit fit;
  /// No frame could be made and every link of the video answered refused (403) or deleted (410).
  final void Function(int code)? onDead;
  const VideoPosterImage({super.key, required this.item, this.cacheWidth = 360, this.fit = BoxFit.cover, this.onDead});
  @override
  State<VideoPosterImage> createState() => _VideoPosterImageState();
}

class _VideoPosterImageState extends State<VideoPosterImage> {
  File? f;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    VideoPoster.need(widget.item);
    VideoPoster.saved.addListener(_savedElsewhere);
    _load();
  }

  void _savedElsewhere() {
    if (f == null) _load();
  }

  @override
  void didUpdateWidget(VideoPosterImage old) {
    super.didUpdateWidget(old);
    if (old.item.url != widget.item.url) {
      VideoPoster.need(widget.item);
      f = null;
      _load();
    }
  }

  @override
  void dispose() {
    _gone = true;
    VideoPoster.saved.removeListener(_savedElsewhere);
    super.dispose();
  }

  Future<void> _load() async {
    final url = widget.item.url;
    final r = await VideoPoster.of(widget.item, wanted: () => !_gone);
    if (!mounted || widget.item.url != url) return;
    if (r != null) {
      setState(() => f = r);
      return;
    }
    // No frame either: check whether the video itself is gone, so the post can move to text or be hidden.
    final dead = widget.onDead;
    if (dead == null) return;
    final code = await VideoPoster.deadCode(widget.item);
    if (code != null && mounted && widget.item.url == url && f == null) dead(code);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = Container(color: cs.surfaceContainerHighest, alignment: Alignment.center, child: const Icon(Icons.movie));
    final file = f;
    if (file == null) return icon;
    return Image.file(file, key: ValueKey(file.path), fit: widget.fit, cacheWidth: widget.cacheWidth, gaplessPlayback: true,
        errorBuilder: (_, _, _) => icon);
  }
}
