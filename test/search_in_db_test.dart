import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/filters.dart';
import 'package:hobee/following.dart';
import 'package:hobee/follows.dart';
import 'package:hobee/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Post post(int i, {String sub = 'pics', String author = 'amy', String title = 'a photo'}) => Post.fromJson({
      'id': 'p$i', 'title': title, 'subreddit': sub, 'author': author, 'permalink': '/p', 'created_utc': 1700000000 + i,
      'url': 'https://i.redd.it/$i.jpg', 'post_hint': 'image', 'selftext': 'some text about nothing in particular',
    })!;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  test('what the database narrows a search down to', () {
    expect(dbSearch('asianpussyass').anyOf, [['asianpussya']]);
    expect(dbSearch('kitties cute').anyOf, [['kitti'], ['cute']], reason: 'word starts, so plurals still match');
    expect(dbSearch('cats OR dogs').anyOf, [['cats', 'dogs']]);
    expect(dbSearch('cats -dogs').anyOf, [['cats']], reason: 'an excluded word is left to the app');
    expect(dbSearch('ab cats').anyOf, [['cats']], reason: 'too short to narrow down');
    final f = dbSearch('u/Amy r/pics sunset');
    expect(f.author?.toLowerCase(), 'amy');
    expect(f.sub?.toLowerCase(), 'pics');
    expect(f.anyOf, [['suns']]);
  });

  test('a 50,000-post feed: the database finds the few matches quickly', () async {
    final d = await Db.db;
    await d.delete('posts');
    const src = 'fol:big';
    final posts = [
      for (var i = 0; i < 50000; i++)
        i % 1000 == 0 ? post(i, sub: 'asianpussyass', title: 'tagged') : post(i, sub: 'sub${i % 300}', author: 'user${i % 500}'),
    ];
    for (var i = 0; i < posts.length; i += 5000) {
      await Db.savePosts(src, posts.sublist(i, i + 5000));
    }
    final sw = Stopwatch()..start();
    final hits = await Db.loadMatching(src, anyOf: dbSearch('asianpussyass').anyOf);
    sw.stop();
    expect(hits, hasLength(50));
    expect(hits.first.created, greaterThan(hits.last.created), reason: 'newest first');
    expect(sw.elapsedMilliseconds, lessThan(5000), reason: 'took ${sw.elapsedMilliseconds} ms');

    expect(await Db.loadMatching(src, sub: 'ASIANPUSSYASS'), hasLength(50), reason: 'r/ filter through the index');
    expect(await Db.loadMatching(src, author: 'user7'), hasLength(100));
    expect(await Db.loadMatching(src, from: 1700000000 + 49990), hasLength(10), reason: 'date range');
    expect(await Db.loadMatching(src, anyOf: [['tagged', 'nothing-like-this']]), hasLength(50));
    await d.delete('posts');
  });

  test('a search naming a followed channel checks it next', () async {
    final d = await Db.db;
    for (final t in ['follows', 'profiles', 'cursors']) {
      await d.delete(t);
    }
    final pid = await FollowStore.createProfile('S');
    await FollowStore.add(pid, const [Follow(FollowKind.sub, 'AsianPussyAss'), Follow(FollowKind.user, 'amy')]);
    final src = followingKey(pid);
    Following.debugReset();
    Following.fetchPage = (f, {int? after, int? before, int limit = 100}) async => [];
    expect((await Following.searchedFor(src, 'asianpussyass'))?.key, 'r/asianpussyass');
    expect((await Following.searchedFor(src, 'u/Amy'))?.key, 'u/amy');
    expect(await Following.searchedFor(src, 'r/amy'), isNull, reason: 'amy is a user here, not a subreddit');
    expect(await Following.searchedFor(src, 'sunset photos'), isNull);
    Following.debugReset();
  });
}
