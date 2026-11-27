import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/models.dart';
import 'package:hobee/saved.dart';
import 'package:hobee/space.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Post post(String id) => Post.fromJson({
      'id': id, 'title': 't', 'subreddit': 'pics', 'author': 'amy', 'permalink': '/p', 'created_utc': 1,
      'url': 'https://i.redd.it/$id.jpg', 'post_hint': 'image',
    })!;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    SharedPreferences.setMockInitialValues({}); // lets the next test pick a profile again
    await Db.debugClose();
    Space.debugReset();
  });

  test('your normal profile keeps every name Hobees always used', () {
    expect(Space.id, 0);
    expect(Space.dbFile('hobee.db'), 'hobee.db');
    expect(Space.galleryDir, 'gallery');
    expect(Space.crashFile, 'crash.log');
    expect(Space.key('appLockPin'), 'appLockPin');
    expect(Space.prefsPrefix(0), 'flutter.');
  });

  test('the panic profile has its own name for each store', () {
    Space.open(1);
    expect(Space.dbFile('hobee.db'), 'hobee_p1.db');
    expect(Space.dbFile('hobee_test_7.db'), 'hobee_test_7_p1.db');
    expect(Space.galleryDir, 'gallery_p1');
    expect(Space.crashFile, 'crash_p1.log');
    expect(Space.key('appLockPin'), 'p1.appLockPin');
    expect(Space.prefsPrefix(1).startsWith(Space.prefsPrefix(0)), isFalse, reason: 'profile 0 must never list its settings');
  });

  test("the panic profile's settings live under its own prefix", () async {
    Space.open(1);
    SharedPreferences.setMockInitialValues({'hobeesP1.theme': 2});
    final sp = await SharedPreferences.getInstance();
    expect(sp.getInt('theme'), 2, reason: 'read from the panic prefix');
    await sp.setInt('lockAfter', 60);
    expect(sp.getKeys(), {'theme', 'lockAfter'});
  });

  test('each profile has its own database', () async {
    await (await Db.db).delete('posts');
    await Db.savePosts('r/pics', [post('real')]);
    await Db.debugClose();
    Space.open(1);
    await (await Db.db).delete('posts');
    expect(await (await Db.db).query('posts'), isEmpty, reason: 'nothing from your normal profile');
    await Db.savePosts('r/pics', [post('panic')]);
    await Db.debugClose();
    Space.debugReset();
    expect([for (final r in await (await Db.db).query('posts')) r['id']], ['real']);
  });

  test('each profile has its own Hobees gallery folder', () async {
    final tmp = await Directory.systemTemp.createTemp('hobees_space');
    addTearDown(() => tmp.delete(recursive: true));
    SavedStore.baseDir = () async => tmp;
    final real = await SavedStore.dir();
    Space.open(1);
    final panic = await SavedStore.dir();
    expect(real.path, isNot(panic.path));
    expect(panic.path.endsWith('gallery_p1'), isTrue);
  });
}
