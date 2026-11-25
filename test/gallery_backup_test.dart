import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/gallery_backup.dart';
import 'package:hobee/saved.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp, zipDir;
  const media = MethodChannel('hobee/media');
  Map<String, String> lastZip = {}; // name inside the zip -> copied bytes path

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('hobees_bk');
    zipDir = await Directory.systemTemp.createTemp('hobees_zip');
    SavedStore.baseDir = () async => tmp;
    await (await Db.db).delete('saved');
    lastZip = {};
    // A pretend zip: 'zip' copies each file aside under its entry name, 'unzip' copies them back out.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(media, (c) async {
      switch (c.method) {
        case 'sdk':
          return 34;
        case 'zip':
          final paths = (c.arguments['paths'] as List).cast<String>();
          final names = (c.arguments['names'] as List).cast<String>();
          for (var i = 0; i < paths.length; i++) {
            final out = '${zipDir.path}/${names[i]}';
            await File(paths[i]).copy(out);
            lastZip[names[i]] = out;
          }
          return 'content://downloads/9';
        case 'unzip':
          final dir = c.arguments['dir'] as String;
          for (final e in lastZip.entries) {
            await File(e.value).copy('$dir/${e.key}');
          }
          return lastZip.keys.toList();
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(media, null);
    for (final d in [tmp, zipDir]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  Future<SavedItem> put(String ext, int at, {String kind = 'image', bool thumb = false}) async {
    final f = await SavedStore.newFile(ext);
    await f.writeAsBytes([at % 256, 1, 2]);
    String? t;
    if (thumb) {
      final tf = await SavedStore.newFile('jpg', suffix: '_t');
      await tf.writeAsBytes([7, 7]);
      t = tf.path;
    }
    final it = SavedItem(path: f.path, kind: kind, thumb: t, postId: 'p$at', subreddit: 'sub$at', author: 'amy',
        permalink: '/r/sub$at/comments/p$at', profile: 2, savedAt: DateTime(2026, 11, 24, 10, 0, at).millisecondsSinceEpoch);
    return SavedItem.fromRow({...it.toRow(), 'id': await SavedStore.add(it)});
  }

  test('a backup holds every file, video stills and the list of where each came from', () async {
    await put('png', 1);
    await put('mp4', 2, kind: 'video', thumb: true);
    final out = await GalleryBackup.backup();
    expect(out, 'content://downloads/9');
    expect(lastZip.keys, containsAll([GalleryBackup.manifestName, '20261124_100001.png', '20261124_100002.mp4', 't_20261124_100002.jpg']));
    final m = jsonDecode(await File(lastZip[GalleryBackup.manifestName]!).readAsString()) as Map;
    expect(m['hobees_backup'], 1);
    final v = (m['items'] as List).firstWhere((e) => e['kind'] == 'video') as Map;
    expect(v['subreddit'], 'sub2');
    expect(v['permalink'], '/r/sub2/comments/p2');
    expect(v['thumb'], 't_20261124_100002.jpg');
    expect(v.containsKey('path'), isFalse, reason: 'no phone paths in the backup');
  });

  test('restore brings back the files and where they came from', () async {
    final a = await put('png', 1);
    final b = await put('mp4', 2, kind: 'video', thumb: true);
    await GalleryBackup.backup();
    await SavedStore.remove([a, b]); // e.g. a fresh install
    expect(await SavedStore.count(), 0);
    final r = await GalleryBackup.restore('content://picked/backup.zip');
    expect((r.added, r.skipped), (2, 0));
    final all = await SavedStore.all();
    final v = all.firstWhere((s) => s.isVideo);
    expect(await File(v.path).readAsBytes(), [2, 1, 2]);
    expect(v.thumb, isNotNull);
    expect(await File(v.thumb!).readAsBytes(), [7, 7]);
    expect(v.subreddit, 'sub2');
    expect(v.permalink, '/r/sub2/comments/p2');
    expect(v.profile, 2);
    expect(v.savedAt, b.savedAt);
    expect(v.path.startsWith(tmp.path), isTrue, reason: 'restored into the private gallery');
  });

  test('restoring twice adds nothing the second time', () async {
    await put('png', 1);
    await put('png', 2);
    await GalleryBackup.backup();
    final r = await GalleryBackup.restore('content://picked/backup.zip');
    expect((r.added, r.skipped), (0, 2));
    expect(await SavedStore.count(), 2);
  });

  test('a zip that is not a Hobees backup is refused', () async {
    final f = File('${zipDir.path}/holiday.jpg');
    await f.writeAsBytes([1]);
    lastZip = {'holiday.jpg': f.path};
    await expectLater(GalleryBackup.restore('content://picked/other.zip'), throwsA(isA<FormatException>()));
    expect(await SavedStore.count(), 0);
  });

  test('an empty gallery has nothing to back up', () async {
    await expectLater(GalleryBackup.backup(), throwsA(isA<StateError>()));
  });
}
