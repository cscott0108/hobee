import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/db.dart';
import 'package:hobee/models.dart';
import 'package:hobee/removed_media.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Post post(String id, {String author = 'someone', String self = ''}) => Post.fromJson({
      'id': id, 'title': 't', 'subreddit': 's', 'author': author, 'permalink': '/p', 'created_utc': 1,
      'url': 'https://i.redd.it/$id.jpg', 'post_hint': 'image', 'selftext': self,
    })!;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await (await Db.db).delete('media_gone');
    RemovedMedia.debugReset();
    MediaCheck.reset();
  });

  test('only a post Reddit marks removed moves to text, and it stays there after a restart', () async {
    final live = post('live1');
    final gone = post('rem1', author: '[deleted]', self: '[deleted]');
    RemovedMedia.refused(live);
    RemovedMedia.refused(gone);
    expect(RemovedMedia.has('live1'), isFalse, reason: 'a live post refusing may just be a blocked host');
    expect(RemovedMedia.has('rem1'), isTrue);
    expect(RemovedMedia.shown(gone).media, isEmpty, reason: 'shown as a text post');
    expect(RemovedMedia.shown(live).media, isNotEmpty);
    await Future.delayed(const Duration(milliseconds: 100)); // the row is written in the background
    RemovedMedia.debugReset();
    await RemovedMedia.load();
    expect(RemovedMedia.has('rem1'), isTrue);
  });

  test('a dead video: removed post to text, live post gone only when deleted (not on a 403)', () {
    RemovedMedia.dead(post('live2'), 403);
    expect(MediaCheck.gone.value, isEmpty);
    RemovedMedia.dead(post('live3'), 410);
    expect(MediaCheck.gone.value, {'live3'});
    RemovedMedia.dead(post('rem2', self: '[removed]'), 403);
    expect(RemovedMedia.has('rem2'), isTrue);
  });
}
