import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/following.dart';
import 'package:hobee/follows.dart';
import 'package:hobee/follows_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final now = DateTime.utc(2026, 11, 25, 12).millisecondsSinceEpoch;
  int ago(Duration d) => (now - d.inMilliseconds) ~/ 1000;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  test('health from the saved check state', () {
    expect(healthOf(FollowState(), now), ChannelHealth.unchecked);
    expect(healthOf(FollowState(at: now, newest: ago(const Duration(days: 1))), now), ChannelHealth.active);
    expect(healthOf(FollowState(at: now, newest: ago(const Duration(days: 20))), now), ChannelHealth.quiet);
    expect(healthOf(FollowState(at: now, newest: ago(const Duration(days: 400))), now), ChannelHealth.dead);
    expect(healthOf(FollowState(at: now, done: true), now), ChannelHealth.dead, reason: 'checked, never any posts');
    expect(healthOf(FollowState(at: now, newest: ago(const Duration(days: 1)), fails: 2), now), ChannelHealth.failing);
    expect(healthOf(FollowState(at: now, newest: ago(const Duration(days: 1)), fails: 1), now), ChannelHealth.active,
        reason: 'one failure is retried before it counts');
  });

  test('status line under a channel', () {
    expect(channelLine(null, now), 'Not checked yet');
    final s = FollowState(at: now - 20 * 60000, newest: ago(const Duration(days: 3)), n: 312, fails: 1, err: 'timed out');
    expect(channelLine(s, now), 'last post 3d ago · checked 20m ago · next in 1 h · 312 saved · failed 1× (timed out)');
  });

  test('failures are kept per channel and cleared by the next good check', () async {
    final d = await Db.db;
    for (final t in ['follows', 'profiles', 'posts', 'cursors']) {
      await d.delete(t);
    }
    final pid = await FollowStore.createProfile('Report');
    await FollowStore.add(pid, const [Follow(FollowKind.sub, 'gone'), Follow(FollowKind.sub, 'fine')]);
    final src = followingKey(pid);
    Following.debugReset();
    Following.minGap = Following.maxGap = Following.gap = Duration.zero;
    Following.budget = 10;
    var broken = true;
    Following.fetchPage = (f, {int? after, int? before, int limit = 100}) async {
      if (f.name == 'gone' && broken) throw Exception('No response in 20 s (timed out)');
      return [
        {'id': '${f.name}1', 'title': 't', 'subreddit': f.name, 'author': 'a', 'permalink': '/p', 'created_utc': ago(const Duration(hours: 2)),
         'url': 'https://i.redd.it/x.jpg', 'post_hint': 'image'},
      ];
    };
    await Following.fetchMore(src, now: DateTime.fromMillisecondsSinceEpoch(now));
    var st = await Following.statesOf(pid);
    expect(st['r/gone']!.fails, 2, reason: 'failed, retried at the end of the round, failed again');
    expect(st['r/gone']!.err, 'timed out');
    expect(healthOf(st['r/gone']!, now), ChannelHealth.failing);
    expect(st['r/fine']!.fails, 0);

    final csv = channelReportCsv(await FollowStore.follows(pid), st, now).split('\n');
    expect(csv.first, startsWith('name,kind,status,'));
    expect(csv.where((l) => l.startsWith('r/gone,subreddit,failing,')), hasLength(1));
    expect(csv.where((l) => l.startsWith('r/fine,subreddit,active,')), hasLength(1));

    broken = false;
    Following.debugReset();
    Following.forceFull(src);
    await Following.fetchMore(src, fromStart: true, now: DateTime.fromMillisecondsSinceEpoch(now + 3600000));
    st = await Following.statesOf(pid);
    expect(st['r/gone']!.fails, 0);
    expect(st['r/gone']!.err, isNull);
  });
}
