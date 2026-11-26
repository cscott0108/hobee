import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/perf_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fields 1–17 of /proc/self/stat; the name in brackets can hold spaces and brackets.
  String stat(int utime, int stime) => '1234 (cott0108 (x) y) S 1 1234 0 0 -1 4194560 100 0 0 0 $utime $stime 0 0';

  tearDown(() {
    PerfLog.debugReset();
    PerfLog.context = () => '';
    PerfLog.work = () => '';
  });

  test('thread count is read from /proc/self/status', () {
    expect(threadsOf('Name:	x
State:	S
Threads:	87
SigQ:	0/1
'), 87);
    expect(threadsOf('Name:	x
'), isNull);
  });

  test('CPU time is read from /proc/self/stat after the process name', () {
    expect(cpuTicksOf(stat(700, 300)), 1000);
    expect(cpuTicksOf('garbage'), isNull);
    expect(cpuTicksOf('1 (a) S 1 2'), isNull);
  });

  test('CPU share of one core', () {
    expect(cpuPercent(100, 1000), 100, reason: '100 ticks at 100 a second = 1 s of CPU in 1 s');
    expect(cpuPercent(50, 10000), 5);
    expect(cpuPercent(300, 1000), 300, reason: 'more than one core');
    expect(cpuPercent(10, 0), 0);
  });

  test('frames that miss 16 ms are counted, with the slowest', () {
    final f = FrameStats()
      ..add(const Duration(milliseconds: 4), const Duration(milliseconds: 6))
      ..add(const Duration(milliseconds: 30), const Duration(milliseconds: 8))
      ..add(const Duration(milliseconds: 5), const Duration(milliseconds: 48));
    expect((f.frames, f.slow, f.worstMs), (3, 2, 48));
    f.reset();
    expect((f.frames, f.slow, f.worstMs), (0, 0, 0));
  });

  test('a sample records CPU since the last one, memory, pictures, frames and what is on screen', () async {
    var ticks = 1000;
    final notes = <String>[];
    PerfLog.readStat = () async => stat(ticks, 0);
    PerfLog.write = (n) async => notes.add(n);
    PerfLog.context = () => 'feed=following;posts=10;shown=8';
    PerfLog.memSplit = () async => {'java': 12, 'native': 300, 'graphics': 90, 'other': 1400, 'pss': 1900};
    PerfLog.readStatus = () async => 'Threads:	64
';
    PerfLog.work = () => 'checks=6/40;hashes=4/120;frames=0/0';

    await PerfLog.sample('first');
    expect(notes.single, startsWith('why=first;cpu=;'), reason: 'no earlier reading to compare with');
    ticks += 5;
    PerfLog.frames.add(const Duration(milliseconds: 20), Duration.zero);
    await PerfLog.sample('timer');
    final n = notes.last;
    expect(n, startsWith('why=timer;cpu='));
    expect(RegExp(r'cpu=\d+;rss_mb=\d+;peak_mb=\d+;img=\d+;img_mb=\d+;img_live=\d+;').hasMatch(n), isTrue, reason: n);
    expect(n, contains('frames=1;slow_frames=1;worst_frame_ms=20'));
    expect(n, contains(';java_mb=12;native_mb=300;graphics_mb=90;other_mb=1400;pss_mb=1900;threads=64'));
    expect(n, endsWith(';checks=6/40;hashes=4/120;frames=0/0;feed=following;posts=10;shown=8'));
    expect(PerfLog.frames.frames, 0, reason: 'frames are counted per sample');
  });

  test('a sample never throws, even when /proc cannot be read', () async {
    final notes = <String>[];
    PerfLog.readStat = () async => throw Exception('no /proc');
    PerfLog.readStatus = () async => throw Exception('no /proc');
    PerfLog.memSplit = () async => throw Exception('no channel');
    PerfLog.work = () => throw StateError('gone');
    PerfLog.write = (n) async => notes.add(n);
    PerfLog.context = () => throw StateError('gone');
    await PerfLog.sample('timer');
    expect(notes.single, startsWith('why=timer;cpu=;'));
  });

  test('before start, moments take no sample (no timers left behind in tests)', () {
    PerfLog.soon('viewer');
    PerfLog.soon('search');
  });
}
