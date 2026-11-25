import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:path_provider/path_provider.dart';
import 'db.dart';
import 'net_guard.dart';

const _media = MethodChannel('hobee/media');

/// Saves [text] into the phone's Downloads as "<base>_<UTC time>.<ext>". Returns where it went.
Future<String> saveTextToDownloads(String base, String ext, String text) async {
  final tmp = File('${(await getTemporaryDirectory()).path}/$base.$ext');
  await tmp.writeAsString(text);
  final ts = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  final mime = ext == 'csv' ? 'text/csv' : 'text/plain';
  return await _media.invokeMethod<String>('download', {'path': tmp.path, 'name': '${base}_$ts.$ext', 'mime': mime}) ?? '';
}

/// One archive request, or a marker (app start, refresh round, setting change).
class PaceEntry {
  final int t; // start, ms since epoch (UTC)
  final String host, caller, kind, result;
  final bool fg; // the app was on screen
  final int inFlight, gapMs, queueMs, replyMs, status, rows;
  final int? resetS;
  final String net, note;

  const PaceEntry({
    required this.t, this.host = '', this.caller = '', this.kind = '', this.result = '', this.fg = false, this.inFlight = 1,
    this.gapMs = 0, this.queueMs = 0, this.replyMs = 0, this.status = 0, this.rows = 0, this.resetS, this.net = '', this.note = '',
  });

  bool get problem => result != 'ok' && result != 'marker';

  Map<String, Object?> toRow() => {
        't': t, 'host': host, 'caller': caller, 'kind': kind, 'fg': fg ? 1 : 0, 'inflight': inFlight, 'gap_ms': gapMs,
        'queue_ms': queueMs, 'reply_ms': replyMs, 'status': status, 'result': result, 'rows': rows, 'reset_s': resetS,
        'net': net, 'note': note,
      };

  static PaceEntry fromRow(Map<String, Object?> r) => PaceEntry(
        t: r['t'] as int, host: r['host'] as String? ?? '', caller: r['caller'] as String? ?? '', kind: r['kind'] as String? ?? '',
        result: r['result'] as String? ?? '', fg: r['fg'] == 1, inFlight: r['inflight'] as int? ?? 1, gapMs: r['gap_ms'] as int? ?? 0,
        queueMs: r['queue_ms'] as int? ?? 0, replyMs: r['reply_ms'] as int? ?? 0, status: r['status'] as int? ?? 0,
        rows: r['rows'] as int? ?? 0, resetS: r['reset_s'] as int?, net: r['net'] as String? ?? '', note: r['note'] as String? ?? '',
      );

  static const csvHeader = 'time_utc,host,caller,kind,on_screen,in_flight,gap_ms,queue_ms,reply_ms,status,result,rows,reset_s,network,note';

  static String _csv(String s) => s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""').replaceAll('\n', ' ')}"' : s;

  String toCsv() => [
        DateTime.fromMillisecondsSinceEpoch(t, isUtc: true).toIso8601String(), host, caller, kind, fg ? 1 : 0, inFlight, gapMs,
        queueMs, replyMs, status, result, rows, resetS ?? '', net, _csv(note),
      ].join(',');
}

/// Kinds of result a request can have.
String paceResult(int status, {bool slowDown = false, bool timeout = false, bool network = false}) {
  if (timeout) return 'timeout';
  if (network) return 'network';
  if (slowDown) return 'slow_down';
  if (status == 429) return 'rate_limited';
  if (status >= 500) return 'server_error';
  if (status == 200) return 'ok';
  return 'http_$status';
}

/// What kind of archive request a URL is: newest posts, paging back, or another endpoint.
String paceKind(Uri u) {
  final path = u.path;
  if (path.endsWith('/posts/search')) {
    if (u.queryParameters.containsKey('after')) return 'newest';
    if (u.queryParameters.containsKey('before')) return 'older';
    return 'posts';
  }
  final parts = path.split('/').where((x) => x.isNotEmpty).toList();
  return parts.length >= 2 ? parts.sublist(parts.length - 2).join('_') : (parts.isEmpty ? 'root' : parts.last);
}

/// The archive pace log: every archive request Hobees makes (when, who asked, how fast it went, what came
/// back, Arctic Shift's reset hints), plus markers, so the fetching pace can be tuned from real numbers. It keeps
/// the newest [keep] rows, stays on the phone and holds no subreddit or user names.
class PaceLog {
  static int keep = 5000;

  /// Set by the background task, so its requests are told apart from the open app's.
  static bool inBackgroundTask = false;

  /// The Following refresher's current gap between requests and requests in flight (set by Following).
  static int gapMs = 0;
  static int inFlight = 1;

  static final _recent = <int>[]; // start times of recent requests (for the counts around a slow-down)
  static int _okStreak = 0;
  static int? _lastProblem;
  static int _sinceTrim = 0;

  static bool get _fg => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  static String netLabel(NetInfo? n) {
    if (n == null) return '';
    final base = switch (n.type) { NetType.wifi => 'wifi', NetType.cellular => 'mobile', NetType.vpn => 'vpn', _ => n.type.name };
    return n.vpn && n.type != NetType.vpn ? '$base+vpn' : base;
  }

  /// Records one request. [message] is the server's text on a problem (shortened).
  static Future<void> request({
    required Uri url, required String caller, required DateTime start, required int queueMs, required int replyMs,
    required String result, int status = 0, int rows = 0, int? resetS, String message = '', int? now,
  }) async {
    final t = start.toUtc().millisecondsSinceEpoch;
    _recent.add(t);
    while (_recent.length > 200) {
      _recent.removeAt(0);
    }
    var note = '';
    if (result != 'ok') {
      final at = now ?? DateTime.now().millisecondsSinceEpoch;
      final last10 = _recent.where((x) => at - x <= 10000).length;
      final last60 = _recent.where((x) => at - x <= 60000).length;
      final since = _lastProblem == null ? '' : '${((at - _lastProblem!) / 1000).round()}s';
      final msg = message.length > 120 ? '${message.substring(0, 120)}…' : message;
      note = 'last10s=$last10;last60s=$last60;ok_streak=$_okStreak;since_last_problem=$since;msg=$msg';
      _okStreak = 0;
      _lastProblem = at;
    } else {
      _okStreak++;
    }
    await add(PaceEntry(
      t: t, host: url.host, caller: caller, kind: paceKind(url), result: result, fg: _safeFg(), inFlight: inFlight, gapMs: gapMs,
      queueMs: queueMs, replyMs: replyMs, status: status, rows: rows, resetS: resetS, net: netLabel(NetGuard.current.value), note: note,
    ));
  }

  static bool _safeFg() {
    try {
      return _fg;
    } catch (_) {
      return false;
    }
  }

  /// A marker: app start, a refresh round starting or ending, a setting change.
  static Future<void> marker(String kind, [String note = '']) =>
      add(PaceEntry(t: DateTime.now().toUtc().millisecondsSinceEpoch, kind: kind, result: 'marker', fg: _safeFg(), note: note,
          caller: inBackgroundTask ? 'background' : 'app', net: netLabel(NetGuard.current.value)));

  static Future<void> add(PaceEntry e) async {
    try {
      final d = await Db.db;
      await d.insert('pace_log', e.toRow());
      if (++_sinceTrim >= 200) {
        _sinceTrim = 0;
        await trim();
      }
    } catch (_) {} // the log must never break a request
  }

  /// Drops all but the newest [keep] rows.
  static Future<void> trim() async {
    final d = await Db.db;
    await d.rawDelete('DELETE FROM pace_log WHERE id <= (SELECT MAX(id) FROM pace_log) - ?', [keep]);
  }

  static Future<List<PaceEntry>> all() async =>
      [for (final r in await (await Db.db).query('pace_log', orderBy: 'id')) PaceEntry.fromRow(r)];

  static Future<List<PaceEntry>> since(Duration d) async {
    final from = DateTime.now().toUtc().millisecondsSinceEpoch - d.inMilliseconds;
    return [for (final r in await (await Db.db).query('pace_log', where: 't >= ?', whereArgs: [from], orderBy: 'id')) PaceEntry.fromRow(r)];
  }

  static Future<String> csv() async => [PaceEntry.csvHeader, for (final e in await all()) e.toCsv()].join('\n');

  /// Writes the log as CSV into Downloads ("Hobees_pace_log_<time>.csv"). Returns where it went.
  static Future<String> saveToDownloads() async => saveTextToDownloads('Hobees_pace_log', 'csv', await csv());

  static Future<void> clear() async => (await Db.db).delete('pace_log');
}

/// Summary of a stretch of the log, for the Archive pace screen.
class PaceSummary {
  final int requests, ok, slowDowns, rateLimited, timeouts, otherProblems, avgReplyMs;
  const PaceSummary(this.requests, this.ok, this.slowDowns, this.rateLimited, this.timeouts, this.otherProblems, this.avgReplyMs);

  static PaceSummary of(List<PaceEntry> es) {
    final reqs = es.where((e) => e.result != 'marker').toList();
    int n(String r) => reqs.where((e) => e.result == r).length;
    final okOnes = reqs.where((e) => e.result == 'ok').toList();
    final avg = okOnes.isEmpty ? 0 : okOnes.fold<int>(0, (a, e) => a + e.replyMs) ~/ okOnes.length;
    final slow = n('slow_down'), rl = n('rate_limited'), to = n('timeout'), ok = okOnes.length;
    return PaceSummary(reqs.length, ok, slow, rl, to, reqs.length - ok - slow - rl - to, avg);
  }
}
