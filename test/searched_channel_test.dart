import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/following.dart';
import 'package:hobee/follows.dart';
import 'package:hobee/gallery.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const ch = Follow(FollowKind.sub, 'AsianPussyAss');

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    Following.checking.value = null;
    Following.lastCheck.value = null;
  });

  testWidgets('the searched channel: checking, then what it found, up to date, or why it failed', (t) async {
    var updates = 0, retries = 0, done = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SearchedChannelRow(
          source: 'fol:1', channel: ch,
          onUpdate: () => updates++, onRetry: () => retries++, onDone: () => done++,
        ),
      ),
    ));
    expect(find.byKey(const Key('searched-channel')), findsNothing, reason: 'nothing known yet');

    Following.checking.value = ch.key;
    await t.pump();
    expect(find.text('Checking r/AsianPussyAss for new posts…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    Following.checking.value = null;
    Following.lastCheck.value = (key: ch.key, posts: 12, media: 31, error: null);
    await t.pump();
    expect(find.text('Found 12 new posts (31 pictures and videos) in r/AsianPussyAss'), findsOneWidget);
    await t.tap(find.byKey(const Key('searched-update')));
    expect((updates, done), (1, 1));

    Following.lastCheck.value = (key: ch.key, posts: 0, media: 0, error: 'timed out');
    await t.pump();
    expect(find.text("Couldn't check r/AsianPussyAss: timed out"), findsOneWidget);
    await t.tap(find.byKey(const Key('searched-retry')));
    expect(retries, 1);

    Following.lastCheck.value = (key: ch.key, posts: 0, media: 0, error: null);
    await t.pump();
    expect(find.text('r/AsianPussyAss is up to date'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    expect(done, 2, reason: 'goes away after a few seconds');

    Following.lastCheck.value = (key: 'r/other', posts: 3, media: 3, error: null);
    await t.pump();
    expect(find.byKey(const Key('searched-channel')), findsNothing, reason: 'another channel');
  });

  test('a check reports the channel, its new posts and the pictures in them', () async {
    final d = await Db.db;
    for (final x in ['follows', 'profiles', 'posts', 'cursors']) {
      await d.delete(x);
    }
    final pid = await FollowStore.createProfile('C');
    await FollowStore.add(pid, const [ch]);
    final src = followingKey(pid);
    Following.debugReset();
    Following.minGap = Following.maxGap = Following.gap = Duration.zero;
    final seen = <String?>[];
    void watch() => seen.add(Following.checking.value);
    Following.checking.addListener(watch);
    Following.fetchPage = (f, {int? after, int? before, int limit = 100}) async => [
          for (var i = 0; i < 3; i++)
            {
              'id': 'g$i', 'title': 't', 'subreddit': f.name, 'author': 'a', 'permalink': '/p', 'created_utc': 1700000000 + i,
              'url': 'https://i.redd.it/$i.jpg', 'post_hint': 'image',
            },
        ];
    await Following.fetchMore(src, now: DateTime.utc(2026, 11, 25));
    Following.checking.removeListener(watch);
    expect(seen, [ch.key, null]);
    expect(Following.lastCheck.value, (key: ch.key, posts: 3, media: 3, error: null));
    Following.debugReset();
  });
}
