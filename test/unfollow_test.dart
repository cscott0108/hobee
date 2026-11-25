import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/following.dart';
import 'package:hobee/follows.dart';
import 'package:hobee/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Post post(String id, String sub, String author) => Post.fromJson({
      'id': id, 'title': 't', 'subreddit': sub, 'author': author, 'permalink': '/p', 'created_utc': 1,
      'url': 'https://i.redd.it/$id.jpg', 'post_hint': 'image',
    })!;

void main() {
  late int pid;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final d = await Db.db;
    await d.delete('posts');
    await d.delete('follows');
    await d.delete('profiles');
    pid = await FollowStore.createProfile('Test');
    await FollowStore.add(pid, const [Follow(FollowKind.sub, 'daddy'), Follow(FollowKind.sub, 'pics'), Follow(FollowKind.user, 'amy')]);
    await Db.savePosts(followingKey(pid), [
      post('a', 'daddy', 'bob'),
      post('b', 'Daddy', 'amy'), // also covered by the followed user
      post('c', 'pics', 'bob'),
      post('d', 'cats', 'amy'),
    ]);
  });

  Future<List<String>> ids() async => [for (final p in await Db.load(followingKey(pid))) p.id]..sort();

  test('unfollowing a subreddit removes its saved posts from the list', () async {
    final n = await Following.unfollow(pid, const Follow(FollowKind.sub, 'daddy'));
    expect(n, 1);
    expect(await ids(), ['b', 'c', 'd'], reason: 'b stays: amy is still followed');
    expect((await FollowStore.follows(pid)).map((f) => f.key), isNot(contains('r/daddy')));
  });

  test('unfollowing a user removes their posts, except in subreddits still followed', () async {
    await Following.unfollow(pid, const Follow(FollowKind.user, 'amy'));
    expect(await ids(), ['a', 'b', 'c'], reason: 'b stays: r/daddy is still followed');
  });

  test('one-time clean-up drops posts of follows removed the old way', () async {
    await FollowStore.remove(pid, const Follow(FollowKind.sub, 'daddy')); // old behaviour: posts stayed
    expect(await ids(), ['a', 'b', 'c', 'd']);
    await Following.pruneOnce(pid);
    expect(await ids(), ['b', 'c', 'd']);
    await Db.savePosts(followingKey(pid), [post('e', 'daddy', 'bob')]);
    await Following.pruneOnce(pid);
    expect(await ids(), contains('e'), reason: 'runs once per list');
  });
}
