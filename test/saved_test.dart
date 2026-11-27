import 'dart:io';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/download.dart';
import 'package:hobee/gallery_export.dart';
import 'package:hobee/models.dart';
import 'package:hobee/saved.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  final calls = <MethodCall>[];
  const media = MethodChannel('hobee/media');

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('hobees_saved');
    SavedStore.baseDir = () async => tmp;
    await (await Db.db).delete('saved');
    calls.clear();
    saveTo.value = SaveTo.hobees;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(media, (c) async {
      calls.add(c);
      return switch (c.method) { 'sdk' => 34, 'save' => 'content://media/1', 'zip' => 'content://downloads/1', _ => null };
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(media, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<SavedItem> put(String ext, int at, {String kind = 'image', String sub = 's'}) async {
    final f = await SavedStore.newFile(ext);
    await f.writeAsBytes([1, 2, 3]);
    final it = SavedItem(path: f.path, kind: kind, postId: 'p$at', subreddit: sub, author: 'a', savedAt: at);
    final id = await SavedStore.add(it);
    return SavedItem.fromRow({...it.toRow(), 'id': id});
  }

  test('saved rows round-trip, newest saved first', () async {
    await put('jpg', 1);
    await put('mp4', 3, kind: 'video', sub: 'v');
    await put('png', 2);
    final all = await SavedStore.all();
    expect([for (final s in all) s.savedAt], [3, 2, 1]);
    expect(all.first.isVideo, isTrue);
    expect(all.first.subreddit, 'v');
    expect(all.first.ext, 'mp4');
    expect(await SavedStore.count(), 3);
  });

  test('a saved video with no picture gets one from its own file, kept and made once', () async {
    SavedStore.debugResetThumbs();
    final asked = <String>[];
    SavedStore.videoFrame = (p) async {
      asked.add(p);
      return Uint8List.fromList([0xff, 0xd8, 1]);
    };
    final v = await put('mp4', 5, kind: 'video');
    final t = await SavedStore.makeThumb(v);
    expect(t, isNotNull);
    expect(File(t!).readAsBytesSync(), [0xff, 0xd8, 1]);
    expect(asked, [v.path], reason: 'read from the saved file, nothing from the web');
    expect((await SavedStore.all()).single.thumb, t);
    expect(await SavedStore.makeThumb(v), isNull, reason: 'once per item');
    expect(asked.length, 1);
  });

  test('files live in the private gallery folder', () async {
    final it = await put('jpg', 1);
    expect(it.path.startsWith('${tmp.path}${Platform.pathSeparator}gallery') || it.path.startsWith('${tmp.path}/gallery'), isTrue);
    expect(isLocalPath(it.path) || Platform.isWindows, isTrue);
  });

  test('delete removes both the file and the row', () async {
    final a = await put('jpg', 1);
    final b = await put('jpg', 2);
    await SavedStore.remove([a]);
    expect(await File(a.path).exists(), isFalse);
    expect(await File(b.path).exists(), isTrue);
    expect([for (final s in await SavedStore.all()) s.id], [b.id]);
  });

  test('a saved item shows in the viewer as a local file', () async {
    final it = await put('jpg', 1);
    expect(it.media.url, it.path);
    expect(it.media.thumb, it.path, reason: 'images use the file itself as the grid picture');
    expect(it.post.media.single.url, it.path);
  });

  group('save destination', () {
    final post = Post('abc', 'title', 'pics', 'amy', '/r/pics/comments/abc', 1700000000, const [], const {});
    final item = MediaItem(MediaType.image, 'https://i.redd.it/x.jpg', '', width: 10, height: 20);

    Future<File> temp() async {
      final f = File('${tmp.path}/dl.png');
      await f.writeAsBytes([9, 9, 9]);
      return f;
    }

    test('Hobees gallery (default): the file is copied into the private folder and a row added, nothing goes to MediaStore', () async {
      final out = await Downloader.store(await temp(), ext: 'png', mime: 'image/png', video: false, item: item, post: post, profile: 4);
      expect(calls.where((c) => c.method == 'save'), isEmpty);
      final all = await SavedStore.all();
      expect(all, hasLength(1));
      expect(all.single.path, out);
      expect(await File(out).readAsBytes(), [9, 9, 9]);
      expect(all.single.subreddit, 'pics');
      expect(all.single.author, 'amy');
      expect(all.single.permalink, '/r/pics/comments/abc');
      expect(all.single.profile, 4);
      expect(all.single.width, 10);
    });

    test('Phone gallery: saved through MediaStore with a timestamp name, no gallery row', () async {
      saveTo.value = SaveTo.phone;
      final out = await Downloader.store(await temp(), ext: 'png', mime: 'image/png', video: false, item: item, post: post);
      expect(out, 'content://media/1');
      final save = calls.singleWhere((c) => c.method == 'save');
      expect(save.arguments['mime'], 'image/png');
      expect(save.arguments['video'], false);
      expect(save.arguments['name'] as String, matches(RegExp(r'^\d{8}_\d{6}\.png$')));
      expect(await SavedStore.count(), 0);
    });
  });

  group('export', () {
    final t1 = DateTime(2026, 11, 24, 21, 5, 9).millisecondsSinceEpoch;

    test('to the phone gallery: one MediaStore save per item, with the saved-time name and the right type', () async {
      final a = await put('png', t1);
      final b = await put('mp4', t1 + 60000, kind: 'video');
      final done = await GalleryExport.toPhone([a, b]);
      expect(done, hasLength(2));
      final saves = calls.where((c) => c.method == 'save').toList();
      expect(saves.map((c) => c.arguments['path']), [a.path, b.path]);
      expect(saves.map((c) => c.arguments['name']), ['20261124_210509.png', '20261124_210609.mp4']);
      expect(saves.map((c) => c.arguments['mime']), ['image/png', 'video/mp4']);
      expect(saves.map((c) => c.arguments['video']), [false, true]);
      expect(await SavedStore.count(), 2, reason: 'export keeps them in Hobees unless you choose to remove them');
    });

    test('as one zip: every file, unique names inside, a Hobees_ zip name', () async {
      final a = await put('jpg', t1);
      final b = await put('jpg', t1 + 300); // same second
      final c = await put('mp4', t1 + 5000, kind: 'video');
      final out = await GalleryExport.toZip([a, b, c]);
      expect(out, 'content://downloads/1');
      final z = calls.singleWhere((c) => c.method == 'zip');
      expect(z.arguments['paths'], [a.path, b.path, c.path]);
      expect(z.arguments['names'], ['20261124_210509.jpg', '20261124_210509_1.jpg', '20261124_210514.mp4']);
      expect(z.arguments['name'] as String, matches(RegExp(r'^Hobees_\d{8}_\d{6}\.zip$')));
      expect(calls.where((c) => c.method == 'save'), isEmpty);
    });

    test('share hands the files and their types to the share sheet', () async {
      final a = await put('png', t1);
      final b = await put('mp4', t1, kind: 'video');
      List<dynamic>? got;
      final keep = GalleryExport.shareFiles;
      GalleryExport.shareFiles = (f) async {
        got = f;
      };
      addTearDown(() => GalleryExport.shareFiles = keep);
      await GalleryExport.share([a, b]);
      expect(got!.map((f) => f.path), [a.path, b.path]);
      expect(got!.map((f) => f.mimeType), ['image/png', 'video/mp4']);
    });
  });

  test('picture size is read from the file header (for tiles saved without a size)', () async {
    final f = await SavedStore.newFile('png');
    await f.writeAsBytes(img.encodePng(img.Image(width: 40, height: 20)));
    expect(await SavedStore.imageSize(f.path), (40, 20));
    final junk = await SavedStore.newFile('png');
    await junk.writeAsBytes([1, 2, 3]);
    expect(await SavedStore.imageSize(junk.path), isNull);
  });
}
