import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/pace_log.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final url = Uri.https('arctic-shift.photon-reddit.com', '/api/posts/search', {'subreddit': 'pics', 'after': '1'});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await PaceLog.clear();
    PaceLog.keep = 5000;
  });

  test('kinds and results', () {
    expect(paceKind(url), 'newest');
    expect(paceKind(Uri.https('h', '/api/posts/search', {'before': '5'})), 'older');
    expect(paceKind(Uri.https('h', '/api/users/search')), 'users_search');
    expect(paceResult(200), 'ok');
    expect(paceResult(422, slowDown: true), 'slow_down');
    expect(paceResult(429), 'rate_limited');
    expect(paceResult(503), 'server_error');
    expect(paceResult(0, timeout: true), 'timeout');
  });

  test('a slow-down records what led up to it; no subreddit or user names are kept', () async {
    final t0 = DateTime.utc(2026, 11, 25, 12);
    for (var i = 0; i < 5; i++) {
      await PaceLog.request(url: url, caller: 'refresher', start: t0.add(Duration(seconds: i * 2)), queueMs: 5, replyMs: 800,
          result: 'ok', status: 200, rows: 3, resetS: 2, now: t0.add(Duration(seconds: i * 2)).millisecondsSinceEpoch);
    }
    final at = t0.add(const Duration(seconds: 10));
    await PaceLog.request(url: url, caller: 'refresher', start: at, queueMs: 0, replyMs: 2400, result: 'slow_down', status: 422,
        message: '{"error":"Timeout. Maybe slow down a bit"}', now: at.millisecondsSinceEpoch);
    final all = await PaceLog.all();
    expect(all, hasLength(6));
    final e = all.last;
    expect(e.problem, isTrue);
    expect(e.kind, 'newest');
    expect(e.note, contains('last10s=6'), reason: 'the 5 requests in the 10 s before, and itself');
    expect(e.note, contains('ok_streak=5'));
    expect(e.note, contains('slow down'));
    expect(all.first.resetS, 2);
    final csv = await PaceLog.csv();
    expect(csv.split('\n').first, PaceEntry.csvHeader);
    expect(csv.split('\n')[1], startsWith('2026-11-25T12:00:00.000Z,arctic-shift.photon-reddit.com,refresher,newest,'));
    expect(csv, isNot(contains('pics')));
  });

  test('keeps only the newest rows', () async {
    PaceLog.keep = 10;
    for (var i = 0; i < 25; i++) {
      await PaceLog.add(PaceEntry(t: i, result: 'ok'));
    }
    await PaceLog.trim();
    final all = await PaceLog.all();
    expect(all, hasLength(10));
    expect(all.first.t, 15);
  });

  test('summary counts requests, not markers', () {
    final s = PaceSummary.of(const [
      PaceEntry(t: 1, result: 'ok', replyMs: 100),
      PaceEntry(t: 2, result: 'ok', replyMs: 300),
      PaceEntry(t: 3, result: 'slow_down'),
      PaceEntry(t: 4, result: 'rate_limited'),
      PaceEntry(t: 5, result: 'marker'),
      PaceEntry(t: 6, result: 'network'),
    ]);
    expect([s.requests, s.ok, s.slowDowns, s.rateLimited, s.timeouts, s.otherProblems, s.avgReplyMs], [5, 2, 1, 1, 0, 1, 200]);
  });
}
