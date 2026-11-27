import 'package:flutter/material.dart';
import 'archive.dart' show isGoneError;
import 'models.dart';
import 'video_poster.dart';

/// Addresses a grid tile can show for [m], in order: the small preview, Reddit's resized copy, and for pictures
/// the original (decoded at tile size). A video's backup copy is a video file, so it isn't tried as a picture. The viewer tries the same ones, so a tile no longer stays broken when
/// the picture itself opens fine.
List<String> tileUrls(MediaItem m) => {
      if (m.thumb.isNotEmpty) m.thumb,
      if (m.type == MediaType.image && (m.preview ?? '').isNotEmpty) m.preview!,
      if (m.type == MediaType.image && m.url.startsWith('http')) m.url,
    }.toList();

/// A grid tile's picture: tries each of [urls] in turn. [onGone] runs once if every one answered 404/410
/// (deleted), not when some just failed to load (offline, slow, blocked).
class TileImage extends StatefulWidget {
  /// Test seam: the picture for one address.
  static Widget Function(String url, int cacheWidth, String? label, ImageErrorWidgetBuilder onError) image = _network;

  static Widget _network(String u, int cacheWidth, String? label, ImageErrorWidgetBuilder onError) => Image.network(
        u,
        key: ValueKey(u),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        semanticLabel: label,
        frameBuilder: (_, child, frame, sync) =>
            sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 180), child: child),
        errorBuilder: onError,
      );

  final List<String> urls;
  final int cacheWidth;
  final String? label;
  final VoidCallback? onGone;
  /// For a video tile: when there's no picture or none loads, show a frame from the video instead.
  final MediaItem? video;
  const TileImage({super.key, required this.urls, this.cacheWidth = 360, this.label, this.onGone, this.video});
  @override
  State<TileImage> createState() => _TileImageState();
}

class _TileImageState extends State<TileImage> {
  int i = 0;
  bool allGone = true;

  @override
  void didUpdateWidget(TileImage old) {
    super.didUpdateWidget(old);
    if (old.urls.join('|') != widget.urls.join('|')) {
      i = 0;
      allGone = true;
    }
  }

  void _failed(Object err) {
    if (!isGoneError(err)) allGone = false;
    final next = i + 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (next < widget.urls.length) {
        setState(() => i = next);
      } else {
        setState(() => i = widget.urls.length);
        if (allGone) widget.onGone?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget broken() => Container(color: cs.surfaceContainerHighest, child: const Icon(Icons.broken_image));
    final v = widget.video;
    if (v != null && (widget.urls.isEmpty || i >= widget.urls.length)) return VideoPosterImage(item: v, cacheWidth: widget.cacheWidth);
    if (widget.urls.isEmpty) return Container(color: cs.surfaceContainerHighest, child: const Icon(Icons.movie));
    if (i >= widget.urls.length) return broken();
    final u = widget.urls[i];
    return TileImage.image(u, widget.cacheWidth, widget.label, (_, err, _) {
      _failed(err);
      return Container(color: cs.surfaceContainerHighest);
    });
  }
}
