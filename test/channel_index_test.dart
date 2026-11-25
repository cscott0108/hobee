import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/following.dart';
import 'package:hobee/follows.dart';
import 'package:hobee/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Post post(String id, String sub, String author, {int t = 1}) => Post.fromJson({
      'id': id, 'title': 't', 'subreddit': sub, 'author': author, 'permalink': '/p', 'created_utc': t,
      'url': 'https://i.redd.it/$id.jpg', 'post_hint': 'image',
    })!;

void main() {
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
    Db.channelsReady = false;
  });
  tearDown(() => Db.channelsReady = false);

  Future<List<Map<String, Object?>>> cols() async =>
      (await Db.db).rawQuery('SELECT id, author, sub FROM posts ORDER BY id');

  test('saved posts get their user and subreddit columns in lower case', () async {
    await Db.savePosts('fol:1', [post('a', 'Pics', 'Amy')]);
    expect(await cols(), [{'id': 'a', 'author': 'amy', 'sub': 'pics'}]);
  });

  test('backfill fills posts saved before the update, then lookups turn on', () async {
    await Db.savePosts('fol:1', [post('a', 'Pics', 'Amy'), post('b', 'cats', 'bob')]);
    await (await Db.db).rawUpdate('UPDATE posts SET author=NULL, sub=NULL'); // as after the upgrade
    expect(await Db.followedChannel(author: 'amy'), isEmpty, reason: 'not ready yet');
    await Db.backfillChannels(pause: Duration.zero);
    expect(Db.channelsReady, true);
    expect(await cols(), [
      {'id': 'a', 'author': 'amy', 'sub': 'pics'},
      {'id': 'b', 'author': 'bob', 'sub': 'cats'},
    ]);
  });

  test('backfill copes with many chunks and unreadable rows', () async {
    final old = Db.chunkRows;
    Db.chunkRows = 7;
    try {
      await Db.savePosts('fol:1', [for (var i = 0; i < 30; i++) post('p$i', 's', 'u$i')]);
      final d = await Db.db;
      await d.rawUpdate('UPDATE posts SET author=NULL, sub=NULL');
      await d.rawUpdate("UPDATE posts SET json='not json' WHERE id='p3'");
      await Db.backfillChannels(pause: Duration.zero);
      expect(await d.rawQuery('SELECT id FROM posts WHERE author IS NULL'), isEmpty);
      expect((await d.rawQuery("SELECT author FROM posts WHERE id='p3'")).single['author'], '');
    } finally {
      Db.chunkRows = old;
    }
  });

  test("a channel's posts across Following lists, each once, newest first; other feeds left out", () async {
    await Db.savePosts('fol:1', [post('a', 'pics', 'amy', t: 1), post('b', 'cats', 'amy', t: 3), post('c', 'pics', 'bob', t: 2)]);
    await Db.savePosts('fol:2', [post('a', 'pics', 'amy', t: 1), post('d', 'pics', 'AMY', t: 4)]);
    await Db.savePosts('deep:amy', [post('e', 'pics', 'amy', t: 5)]);
    await Db.backfillChannels(pause: Duration.zero);
    expect([for (final p in await Db.followedChannel(author: 'Amy')) p.id], ['d', 'b', 'a']);
    expect([for (final p in await Db.followedChannel(sub: 'PICS')) p.id], ['d', 'c', 'a']);
    expect([for (final p in await Db.followedChannel(author: 'amy', sub: 'pics')) p.id], ['d', 'a']);
  });

  test('a channel page with nothing saved starts from the Following posts; searches and filled pages are left alone', () async {
    await Db.savePosts('fol:1', [post('a', 'pics', 'amy', t: 1), post('b', 'cats', 'amy', t: 2), post('c', 'pics', 'bob', t: 3)]);
    expect(await Following.seedChannel('deep:amy'), 0, reason: 'not indexed yet');
    await Db.backfillChannels(pause: Duration.zero);
    expect(await Following.seedChannel('deep:amy'), 2);
    expect([for (final p in await Db.load('deep:amy')) p.id], ['b', 'a']);
    expect(await Following.seedChannel('deep:amy'), 0, reason: 'already has posts');
    expect(await Following.seedChannel('deep:amy@pics'), 1);
    expect(await Following.seedChannel('sr:pics'), 2);
    expect(await Following.seedChannel('sr:cats?q=kitten'), 0);
    expect(await Following.seedChannel('fol:1'), 0);
    expect(await Following.seedChannel('deep:nobody'), 0);
  });

  test('unfollow uses the index once ready and keeps posts another follow covers', () async {
    final pid = await FollowStore.createProfile('Test');
    await FollowStore.add(pid, const [Follow(FollowKind.sub, 'daddy'), Follow(FollowKind.user, 'amy')]);
    await Db.savePosts(followingKey(pid), [post('a', 'daddy', 'bob'), post('b', 'Daddy', 'amy'), post('c', 'pics', 'amy')]);
    await Db.backfillChannels(pause: Duration.zero);
    expect(await Following.unfollow(pid, const Follow(FollowKind.sub, 'Daddy')), 1);
    expect([for (final p in await Db.load(followingKey(pid))) p.id]..sort(), ['b', 'c']);
  });
}
