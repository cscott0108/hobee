import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/follow_button.dart';
import 'package:hobee/following.dart';
import 'package:hobee/follows.dart';
import 'package:hobee/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 30; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 50)); // also runs the bottom sheet's animation
    }
  }

  testWidgets('follow from a subreddit page, then unfollow (its saved posts go too)', (t) async {
    final pid = (await t.runAsync(() async {
      final d = await Db.db;
      await d.delete('follows');
      await d.delete('profiles');
      await d.delete('posts');
      return FollowStore.createProfile('Main');
    }))!;
    const f = Follow(FollowKind.sub, 'pics');
    await t.pumpWidget(MaterialApp(home: Scaffold(appBar: AppBar(actions: const [FollowButton(f)]))));
    await settle(t);
    expect(find.byKey(const Key('follow-button')), findsOneWidget);

    await t.tap(find.byKey(const Key('follow-button')));
    await settle(t);
    await t.tap(find.byKey(Key('follow-list-$pid')));
    await settle(t);
    expect(await t.runAsync(() => FollowStore.listsWith(f)), {pid});
    expect(find.byKey(const Key('following-button')), findsOneWidget, reason: 'filled icon once followed');

    await t.runAsync(() => Db.savePosts(followingKey(pid), [
          Post.fromJson({'id': 'x', 'title': 't', 'subreddit': 'pics', 'author': 'a', 'permalink': '/p', 'created_utc': 1, 'url': 'https://i.redd.it/x.jpg'})!,
        ]));
    await t.tap(find.byKey(Key('follow-list-$pid')));
    await settle(t);
    expect(await t.runAsync(() => FollowStore.listsWith(f)), isEmpty);
    expect(await t.runAsync(() => Db.load(followingKey(pid))), isEmpty, reason: 'unfollowing drops its saved posts');
    await t.pumpWidget(const SizedBox());
  });
}
