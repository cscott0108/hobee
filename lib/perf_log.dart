import 'dart:async';
import 'dart:io';
import 'dart:ui' show FrameTiming;
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'pace_log.dart';

/// CPU time Hobees has used so far (utime + stime, in clock ticks) from the text of /proc/self/stat.
int? cpuTicksOf(String stat) {
  final i = stat.lastIndexOf(')'); // the process name (field 2) may hold spaces
  if (i < 0 || i + 2 > stat.length) return null;
  final f = stat.substring(i + 2).split(' ');
  if (f.length < 13) return null; // f[0] is field 3, so utime (14) is f[11] and stime (15) f[12]
  final u = int.tryParse(f[11]), s = int.tryParse(f[12]);
  return u == null || s == null ? null : u + s;
}

/// Share of one CPU core, in percent, for [ticks] of CPU time over [ms] of wall time ([hz] ticks a second).
int cpuPercent(int ticks, int ms, {int hz = 100}) => ms <= 0 ? 0 : (ticks * 100000 / (hz * ms)).round();

/// Frames since the last sample: how many, how many missed the 16 ms budget, and the slowest (build or raster).
class FrameStats {
  int frames = 0, slow = 0, worstMs = 0;
  void add(Duration build, Duration raster) {
    final ms = (build > raster ? build : raster).inMicroseconds / 1000;
    frames++;
    if (ms > 16) slow++;
    if (ms > worstMs) worstMs = ms.ceil();
  }

  void reset() => frames = slow = worstMs = 0;
}

/// One performance sample, as the pace log's note.
String perfNote({
  required String why, int? cpu, required int rssMb, required int peakMb, required int imgCount, required int imgMb,
  required int imgLive, required FrameStats f, String context = '',
}) =>
    'why=$why;cpu=${cpu ?? ''};rss_mb=$rssMb;peak_mb=$peakMb;img=$imgCount;img_mb=$imgMb;img_live=$imgLive;'
    'frames=${f.frames};slow_frames=${f.slow};worst_frame_ms=${f.worstMs}${context.isEmpty ? '' : ';$context'}';

/// Performance samples in the pace log (rows of kind `perf`): CPU, memory, picture cache and smoothness every
/// [every] while Hobees is on screen, and shortly after moments that cost work (switching feeds, searching,
/// opening the viewer). Nothing is sampled in the background, and nothing leaves the phone.
class PerfLog {
  static const every = Duration(seconds: 30);

  /// How long after a moment (a search, a feed switch) its sample is taken, so the sample shows the work it caused.
  static const settle = Duration(seconds: 2);

  /// What's on screen, without names (set by the grid): "feed=following;posts=…;shown=…".
  static String Function() context = () => '';

  /// Test seams.
  static Future<String> Function() readStat = () => File('/proc/self/stat').readAsString();
  static Future<void> Function(String note) write = (n) => PaceLog.marker('perf', n);

  static final frames = FrameStats();
  static Timer? _timer;
  static final _soon = <String, Timer>{};
  static int? _ticks, _at;
  static bool _started = false;
  static final _observer = _Lifecycle();

  static void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_timings);
    WidgetsBinding.instance.addObserver(_observer);
    _resume();
  }

  static void _timings(List<FrameTiming> ts) {
    for (final t in ts) {
      frames.add(t.buildDuration, t.rasterDuration);
    }
  }

  static void _resume() {
    _timer?.cancel();
    _ticks = null; // time spent in the background doesn't count
    unawaited(_baseline());
    frames.reset();
    _timer = Timer.periodic(every, (_) => sample('timer'));
  }

  static void _pause() {
    _timer?.cancel();
    _timer = null;
    for (final t in _soon.values) {
      t.cancel();
    }
    _soon.clear();
  }

  static Future<void> _baseline() async {
    _ticks = await _readTicks();
    _at = DateTime.now().millisecondsSinceEpoch;
  }

  static Future<int?> _readTicks() async {
    try {
      return cpuTicksOf(await readStat());
    } catch (_) {
      return null;
    }
  }

  /// A sample [settle] after [why] happened (a later one of the same kind moves it on, so typing gives one).
  static void soon(String why) {
    if (!_started || _timer == null) return;
    _soon[why]?.cancel();
    _soon[why] = Timer(settle, () {
      _soon.remove(why);
      sample(why);
    });
  }

  /// Takes a sample now.
  static Future<void> sample(String why) async {
    try {
      final ticks = await _readTicks();
      final now = DateTime.now().millisecondsSinceEpoch;
      final before = _ticks, at = _at;
      final cpu = ticks == null || before == null || at == null ? null : cpuPercent(ticks - before, now - at);
      _ticks = ticks;
      _at = now;
      final cache = PaintingBinding.instance.imageCache;
      final note = perfNote(
        why: why, cpu: cpu, rssMb: ProcessInfo.currentRss >> 20, peakMb: ProcessInfo.maxRss >> 20,
        imgCount: cache.currentSize, imgMb: cache.currentSizeBytes >> 20, imgLive: cache.liveImageCount, f: frames,
        context: _context(),
      );
      frames.reset();
      await write(note);
    } catch (_) {} // the log must never break the app
  }

  static String _context() {
    try {
      return context();
    } catch (_) {
      return '';
    }
  }

  static void debugReset() {
    _pause();
    _ticks = _at = null;
    frames.reset();
  }
}

class _Lifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      PerfLog._resume();
    } else if (PerfLog._timer != null) {
      PerfLog.sample('leave').ignore();
      PerfLog._pause();
    }
  }
}
