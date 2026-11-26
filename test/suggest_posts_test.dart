import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
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
    await (await Db.db).delete('posts');
    Db.channelsReady = true;
  });
  tearDown(() => Db.channelsReady = false);

  test('suggestions read what you viewed and searched, never the Following lists', () async {
    await Db.savePosts('fol:1', [for (var i = 0; i < 50; i++) post('f$i', 'pics', 'amy', t: 100 + i)]);
    await Db.savePosts('deep:amy', [post('a', 'pics', 'amy', t: 5), post('b', 'cats', 'amy', t: 9)]);
    await Db.savePosts('r/pics', [post('a', 'pics', 'amy', t: 5), post('c', 'pics', 'bob', t: 7)]);
    expect([for (final p in await Db.loadForSuggestions()) p.id], ['b', 'c', 'a'], reason: 'each post once, newest first');
  });

  test('only the newest few are read, however many are saved', () async {
    await Db.savePosts('deep:amy', [for (var i = 0; i < 40; i++) post('p$i', 'pics', 'amy', t: i)]);
    final got = await Db.loadForSuggestions(cap: 10);
    expect(got.length, 10);
    expect(got.first.id, 'p39');
    expect(got.last.id, 'p30');
  });

  test("a user's subreddits come from the index, Following lists included, each post once", () async {
    await Db.savePosts('fol:1', [post('a', 'Pics', 'Amy'), post('b', 'cats', 'amy'), post('c', 'pics', 'bob')]);
    await Db.savePosts('fol:2', [post('a', 'Pics', 'Amy')]);
    await Db.savePosts('deep:amy', [post('d', 'pics', 'AMY'), post('e', 'u_amy', 'amy')]);
    expect(await Db.subsOf('Amy'), {'pics': 2, 'cats': 1, 'u_amy': 1});
    expect(await Db.subsOf('nobody'), isEmpty);
  });

  test('before the index is filled, nothing is looked up', () async {
    await Db.savePosts('fol:1', [post('a', 'pics', 'amy')]);
    Db.channelsReady = false;
    expect(await Db.subsOf('amy'), isEmpty);
  });
}
