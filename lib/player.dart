import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'embeds.dart';
import 'models.dart';
import 'net_guard.dart';
import 'saved.dart';
import 'screen_awake.dart';
import 'video_poster.dart';

/// Player settings, saved.
class VideoPrefs {
  static final startMuted = ValueNotifier<bool>(false);
  static final muted = ValueNotifier<bool>(false);
  static final loop = ValueNotifier<bool>(true);
  static final speed = ValueNotifier<double>(1);
  /// Play over music or podcasts instead of pausing them (no audio focus). Muted videos always do.
  static final mixAudio = ValueNotifier<bool>(false);
  /// Swiping to a video shows its first frame and waits for a tap on play.
  static final startPaused = ValueNotifier<bool>(false);
  /// Right-hand time label: true shows time left (-1:23), false the total length. Tap it to switch.
  static final showRemaining = ValueNotifier<bool>(true);
  static final _pos = <String, int>{};
  static SharedPreferences? _sp;

  static Future<void> load() async {
    final sp = _sp = await SharedPreferences.getInstance();
    startMuted.value = sp.getBool('startMuted') ?? false;
    muted.value = sp.getBool('videoMuted') ?? startMuted.value;
    loop.value = sp.getBool('videoLoop') ?? true;
    speed.value = sp.getDouble('videoSpeed') ?? 1;
    showRemaining.value = sp.getBool('videoRemaining') ?? true;
    mixAudio.value = sp.getBool('videoMixAudio') ?? false;
    startPaused.value = sp.getBool('videoStartPaused') ?? false;
    mixAudio.addListener(() => sp.setBool('videoMixAudio', mixAudio.value));
    startPaused.addListener(() => sp.setBool('videoStartPaused', startPaused.value));
    showRemaining.addListener(() => sp.setBool('videoRemaining', showRemaining.value));
    startMuted.addListener(() {
      sp.setBool('startMuted', startMuted.value);
      muted.value = startMuted.value;
    });
    muted.addListener(() => sp.setBool('videoMuted', muted.value));
    loop.addListener(() => sp.setBool('videoLoop', loop.value));
    speed.addListener(() => sp.setDouble('videoSpeed', speed.value));
    for (final k in sp.getKeys().where((k) => k.startsWith('vpos:'))) {
      _pos[k.substring(5)] = sp.getInt(k) ?? 0;
    }
  }

  /// Whether a video opened now leaves other apps' audio playing.
  static bool get mixes => mixAudio.value || muted.value;

  static int resumeAt(String url) => _pos[url] ?? 0;

  /// Remember where you left off (skip near the start/end and short clips).
  static void savePos(String url, Duration at, Duration total) {
    final keep = total.inSeconds >= 20 && at.inSeconds > 3 && at < total - const Duration(seconds: 3);
    if (keep) {
      _pos[url] = at.inMilliseconds;
      _sp?.setInt('vpos:$url', at.inMilliseconds);
    } else if (_pos.remove(url) != null) {
      _sp?.remove('vpos:$url');
    }
  }
}

String fmtDur(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, ss = s % 60;
  String two(int x) => x.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(ss)}' : '$m:${two(ss)}';
}

/// Right-hand player label: time left ("-1:23") or the total length.
String endLabel(Duration pos, Duration total, {required bool remaining}) {
  if (!remaining) return fmtDur(total);
  final left = total - pos;
  return '-${fmtDur(left.isNegative ? Duration.zero : left)}';
}

/// Height of the viewer's bottom info panel while it shows (0 when hidden), so the player's controls sit
/// above it instead of underneath.
final viewerChromeInset = ValueNotifier<double>(0);

/// True while the current image or video is zoomed in. The viewer hides its blurred panels then (they had
/// to re-blur on every zoom frame) and, for videos, stops swiping to the next item until you zoom out.
final viewerZoomed = ValueNotifier<bool>(false);

/// Whether the current video's controls are showing. The video takes every tap, so the viewer shows and
/// hides its title bar and user / subreddit chips together with the controls.
final videoControlsShown = ValueNotifier<bool>(true);

/// Sources to try in order: HLS (has sound) or the resolved mp4, then the plain mp4, then Reddit's preview clip.
Future<List<(String, bool)>> videoSources(MediaItem it) async {
  if (isLocalPath(it.url)) return [(it.url, false)]; // a saved file (Hobees gallery)
  final out = <(String, bool)>[];
  final hls = it.hls ?? Embeds.redditHls(it.url);
  if (hls != null) out.add((hls, true));
  try {
    out.add((await Embeds.playable(it.url), false));
  } catch (_) {}
  if (it.preview != null && it.preview!.isNotEmpty) out.add((it.preview!, false));
  return out;
}

/// What [host] answered when no copy played. Only hosts and status codes: no names or links.
typedef VideoFail = (String host, int? code);

String hostOf(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h.isEmpty ? 'the host' : h;
}

/// The status a host gives [url] (a one-byte request), or null when it doesn't answer. Only asked after the
/// player failed, to say why.
Future<int?> probeStatus(String url) async {
  if (isLocalPath(url)) return null;
  try {
    final rq = http.Request('GET', Uri.parse(url))..headers.addAll({'User-Agent': Embeds.ua, 'Range': 'bytes=0-0'});
    final r = await Embeds.client.send(rq).timeout(const Duration(seconds: 8));
    await r.stream.listen((_) {}).cancel();
    return r.statusCode;
  } catch (_) {
    return null;
  }
}

bool _refused(int? code) => code == 401 || code == 403 || code == 404 || code == 410;

/// Title and detail lines for a video no copy of which played.
(String, String) videoErrorText(List<VideoFail> fails) {
  if (fails.isEmpty) return ("Can't play this one", 'No playable copy found');
  String line(VideoFail f) => switch (f.$2) {
        null => '${f.$1}: no answer',
        403 => '${f.$1} refused it (403)',
        404 => '${f.$1}: not found (404)',
        410 => '${f.$1}: gone (410)',
        final c when c >= 200 && c < 300 => "${f.$1} answered, but the video wouldn't open",
        final c => '${f.$1} answered $c',
      };
  final lines = <String>[];
  for (final f in fails) {
    final l = line(f);
    if (!lines.contains(l)) lines.add(l);
  }
  final gone = fails.every((f) => _refused(f.$2));
  return (gone ? 'Removed from its host' : "Can't play this one", lines.join('\n'));
}

class VideoPage extends StatefulWidget {
  final MediaItem item;
  final bool active;
  const VideoPage({super.key, required this.item, required this.active});
  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  VideoPlayerController? c;
  String? err;
  String errTitle = "Can't play this one";
  bool ui = true, full = false, dragging = false;
  double dragTo = 0;
  Timer? hide;
  String? flash; // "-10s" / "+10s"
  Timer? flashT;
  final _zoom = TransformationController();
  bool zoomed = false;

  /// Pinch zoom: one finger pans only while zoomed in, so a plain swipe still goes to the next item.
  void _zoomEnd(ScaleEndDetails _) {
    final z = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (z == zoomed) return;
    setState(() => zoomed = z);
    if (widget.active) viewerZoomed.value = z;
  }

  void _resetZoom() {
    _zoom.value = Matrix4.identity();
    if (zoomed) setState(() => zoomed = false);
    if (widget.active) viewerZoomed.value = false;
  }

  @override
  void initState() {
    super.initState();
    NetGuard.decision.addListener(_netChanged);
    NetGuard.onMobileData.addListener(_netChanged);
    if (widget.active) _init(); // neighbours stay cold: at most the visible video holds a decoder
  }

  bool _initing = false, _wasPlaying = false;
  DateTime _lastSave = DateTime(2000);

  Future<void> _init() async {
    if (_initing || c != null) return;
    _initing = true;
    try {
      await _open();
    } finally {
      _initing = false;
    }
  }

  void _release() {
    final v = c;
    if (v == null) return;
    if (v.value.isInitialized) VideoPrefs.savePos(widget.item.url, v.value.position, v.value.duration);
    v.removeListener(_tick);
    v.dispose();
    c = null;
    if (_wasPlaying) ScreenAwake.videoPlaying(false);
    _wasPlaying = false;
  }

  /// Wi-Fi safety paused the app: wait, and start once the network is allowed again.
  bool _netPaused = false;

  void _netChanged() {
    if (!_netPaused || NetGuard.paused || !mounted) return;
    setState(() {
      _netPaused = false;
      err = null;
    });
    if (widget.active) _init();
  }

  Future<void> _open() async {
    if (NetGuard.paused && !isLocalPath(widget.item.url)) {
      if (mounted) setState(() { _netPaused = true; err = 'Paused on an untrusted Wi-Fi'; });
      return;
    }
    final srcs = await videoSources(widget.item);
    final fails = <VideoFail>[];
    final tried = <String>{};
    for (final (u, hls) in srcs) {
      if (!tried.add(u)) continue;
      if (await _try(u, hls)) return;
      fails.add((hostOf(u), await probeStatus(u)));
    }
    // A refused RedGIFs / Streamable link may only have expired: ask the host for a fresh one, once.
    final it = widget.item.url;
    if (fails.any((f) => _refused(f.$2)) && (Embeds.redgifsId(it) != null || Embeds.streamableId(it) != null)) {
      try {
        final u = await Embeds.playable(it, fresh: true);
        if (tried.add(u)) {
          if (await _try(u, false)) return;
          fails.add((hostOf(u), await probeStatus(u)));
        }
      } catch (e) {
        if ('$e'.contains('Gone')) fails.add((hostOf(it), 410));
      }
    }
    if (!mounted) return;
    final (title, detail) = videoErrorText(fails);
    setState(() {
      errTitle = title;
      err = detail;
    });
  }

  /// Open [u] in the player. True when it plays (or the page went away meanwhile).
  Future<bool> _try(String u, bool hls) async {
    final opts = VideoPlayerOptions(mixWithOthers: VideoPrefs.mixes);
    final ctrl = isLocalPath(u)
        ? VideoPlayerController.file(File(u), videoPlayerOptions: opts)
        : VideoPlayerController.networkUrl(Uri.parse(u),
            formatHint: hls ? VideoFormat.hls : null, httpHeaders: const {'User-Agent': Embeds.ua}, videoPlayerOptions: opts);
    try {
      await ctrl.initialize();
      await ctrl.setLooping(VideoPrefs.loop.value);
      await ctrl.setVolume(VideoPrefs.muted.value ? 0 : 1);
      await ctrl.setPlaybackSpeed(VideoPrefs.speed.value);
      final at = VideoPrefs.resumeAt(widget.item.url);
      if (at > 0) await ctrl.seekTo(Duration(milliseconds: at));
      if (!mounted || !widget.active) {
        await ctrl.dispose();
        return true;
      }
      ctrl.addListener(_tick);
      setState(() => c = ctrl);
      unawaited(VideoPoster.fromPlaying(widget.item, u, hls: hls)); // a tile with no picture gets this video's frame
      if (widget.active && !VideoPrefs.startPaused.value) _play();
      return true;
    } catch (_) {
      ctrl.dispose();
      return false;
    }
  }

  /// Try again from the start, asking for fresh links.
  void _retry() {
    Embeds.forget(widget.item.url);
    setState(() {
      err = null;
      errTitle = "Can't play this one";
    });
    _init();
  }

  void _tick() {
    final v = c!.value;
    if (v.isPlaying != _wasPlaying) {
      _wasPlaying = v.isPlaying;
      ScreenAwake.videoPlaying(v.isPlaying);
    }
    final now = DateTime.now();
    if (v.isInitialized && now.difference(_lastSave).inSeconds >= 5) {
      _lastSave = now; // was a prefs write on every frame tick
      VideoPrefs.savePos(widget.item.url, v.position, v.duration);
    }
    if (mounted && !dragging) setState(() {});
  }

  void _play() {
    c?.play();
    _autoHide();
  }

  void _autoHide() {
    hide?.cancel();
    hide = Timer(const Duration(seconds: 3), () {
      if (mounted && (c?.value.isPlaying ?? false) && !dragging) _setUi(false);
    });
  }

  void _setUi(bool v) {
    setState(() => ui = v);
    if (widget.active) videoControlsShown.value = v;
  }

  void _toggleUi() {
    _setUi(!ui);
    if (ui) _autoHide();
  }

  void _skip(int s) {
    final v = c;
    if (v == null) return;
    var to = v.value.position + Duration(seconds: s);
    if (to < Duration.zero) to = Duration.zero;
    if (to > v.value.duration) to = v.value.duration;
    v.seekTo(to);
    flashT?.cancel();
    setState(() => flash = s > 0 ? '+${s}s' : '${s}s');
    flashT = Timer(const Duration(milliseconds: 600), () => mounted ? setState(() => flash = null) : null);
  }

  Future<void> _fullscreen() async {
    full = !full;
    if (full) {
      final ar = c?.value.aspectRatio ?? 1.7;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(ar >= 1
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp]);
    } else {
      await _exitFull();
    }
    if (mounted) setState(() {});
  }

  Future<void> _exitFull() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([]);
  }

  @override
  void didUpdateWidget(VideoPage old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    if (widget.active) {
      ui = true; // controls show again when you swipe back to this video (the viewer's panels show with them)
      if (c == null) {
        _init();
      } else if (!VideoPrefs.startPaused.value) {
        _play();
      }
    } else {
      if (full) {
        full = false;
        _exitFull();
      }
      _release(); // free the decoder as soon as you swipe away
      _zoom.value = Matrix4.identity();
      zoomed = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    NetGuard.decision.removeListener(_netChanged);
    NetGuard.onMobileData.removeListener(_netChanged);
    hide?.cancel();
    flashT?.cancel();
    _zoom.dispose();
    _release();
    if (full) _exitFull();
    super.dispose();
  }

  Widget _btn(IconData i, VoidCallback f, {String? tip, bool on = true}) => IconButton(
        tooltip: tip,
        icon: Icon(i, color: on ? Colors.white : Colors.white38, size: 22),
        onPressed: () {
          f();
          _autoHide();
        },
      );

  @override
  Widget build(BuildContext context) {
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(errTitle, key: const Key('video-err-title'), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(err!, key: const Key('video-err'), style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('video-retry'),
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            ),
          ]),
        ),
      );
    }
    final v = c;
    if (v == null) return const Center(child: CircularProgressIndicator());
    final val = v.value;
    final total = val.duration;
    final pos = dragging ? Duration(milliseconds: dragTo.round()) : val.position;
    final w = MediaQuery.sizeOf(context).width;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleUi,
      // Double tap: zoomed in → back to normal size; otherwise skip 10 s back (left half) or ahead (right half).
      onDoubleTapDown: (d) => zoomed ? _resetZoom() : _skip(d.localPosition.dx < w / 2 ? -10 : 10),
      onDoubleTap: () {},
      child: Container(
        color: Colors.black,
        child: Stack(alignment: Alignment.center, children: [
          Positioned.fill(
            child: InteractiveViewer(
              key: const Key('video-zoom'),
              transformationController: _zoom,
              minScale: 1,
              maxScale: 4,
              panEnabled: zoomed,
              onInteractionEnd: _zoomEnd,
              child: Center(child: AspectRatio(aspectRatio: val.aspectRatio, child: VideoPlayer(v))),
            ),
          ),
          if (val.isBuffering) const CircularProgressIndicator(color: Colors.white70),
          if (flash != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(flash!, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            ),
          // Fills the page: the old Stack was only as big as the play button, which squeezed the control bar
          // into a thin dark strip above it.
          Positioned.fill(
           child: IgnorePointer(
            ignoring: !ui,
            child: AnimatedOpacity(
              opacity: ui ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Stack(fit: StackFit.expand, children: [
                Center(child: Material(
                  color: Colors.black45,
                  shape: const CircleBorder(),
                  child: IconButton(
                    iconSize: 56, tooltip: val.isPlaying ? 'Pause' : 'Play',
                    icon: Icon(val.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                    onPressed: () {
                      if (val.isPlaying) {
                        v.pause();
                        hide?.cancel();
                      } else {
                        if (val.position >= total && total > Duration.zero) v.seekTo(Duration.zero);
                        _play();
                      }
                    },
                  ),
                )),
                ValueListenableBuilder(
                  valueListenable: viewerChromeInset,
                  builder: (_, inset, bar) => Positioned(left: 0, right: 0, bottom: full ? 8 : inset + 8, child: bar!),
                  child: Container(
                    key: const Key('video-controls'),
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        Text(fmtDur(pos), style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              activeTrackColor: const Color(0xFFE53935),
                              thumbColor: const Color(0xFFE53935),
                              inactiveTrackColor: Colors.white24,
                            ),
                            child: Slider(
                              value: pos.inMilliseconds.clamp(0, total.inMilliseconds).toDouble(),
                              max: total.inMilliseconds <= 0 ? 1 : total.inMilliseconds.toDouble(),
                              onChangeStart: (x) => setState(() {
                                dragging = true;
                                dragTo = x;
                                hide?.cancel();
                              }),
                              onChanged: (x) => setState(() => dragTo = x),
                              onChangeEnd: (x) async {
                                await v.seekTo(Duration(milliseconds: x.round()));
                                if (!mounted) return;
                                setState(() => dragging = false);
                                _autoHide();
                              },
                            ),
                          ),
                        ),
                        GestureDetector(
                          key: const Key('video-end-label'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            VideoPrefs.showRemaining.value = !VideoPrefs.showRemaining.value;
                            setState(() {});
                            _autoHide();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(endLabel(pos, total, remaining: VideoPrefs.showRemaining.value),
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
                          ),
                        ),
                      ]),
                      Row(children: [
                        _btn(VideoPrefs.muted.value ? Icons.volume_off : Icons.volume_up, () {
                          VideoPrefs.muted.value = !VideoPrefs.muted.value;
                          v.setVolume(VideoPrefs.muted.value ? 0 : 1);
                          setState(() {});
                        }, tip: 'Sound'),
                        _btn(Icons.repeat, () {
                          VideoPrefs.loop.value = !VideoPrefs.loop.value;
                          v.setLooping(VideoPrefs.loop.value);
                          setState(() {});
                        }, tip: 'Loop', on: VideoPrefs.loop.value),
                        PopupMenuButton<double>(
                          tooltip: 'Speed',
                          initialValue: VideoPrefs.speed.value,
                          onSelected: (s) {
                            VideoPrefs.speed.value = s;
                            v.setPlaybackSpeed(s);
                            _autoHide();
                          },
                          itemBuilder: (_) => [
                            for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]) PopupMenuItem(value: s, child: Text('${s}x')),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Text('${VideoPrefs.speed.value}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const Spacer(),
                        _btn(Icons.replay_10, () => _skip(-10), tip: 'Back 10s'),
                        _btn(Icons.forward_10, () => _skip(10), tip: 'Ahead 10s'),
                        _btn(full ? Icons.fullscreen_exit : Icons.fullscreen, _fullscreen, tip: 'Full screen'),
                      ]),
                    ]),
                  ),
                ),
              ]),
            ),
           ),
          ),
        ]),
      ),
    );
  }
}
