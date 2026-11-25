import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/download_dupes.dart';
import 'package:hobee/download_dupes_ui.dart';
import 'package:hobee/downloaded.dart';
import 'package:hobee/models.dart';
import 'package:hobee/saved.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Post post(String id) => Post.fromJson({
      'id': id, 'title': 't $id', 'subreddit': 'pics', 'author': 'amy', 'permalink': '/p', 'created_utc': 1700000000,
      'url': 'https://i.redd.it/$id.jpg', 'post_hint': 'image',
    })!;

MediaItem item(String name) => MediaItem(MediaType.image, 'https://i.redd.it/$name.jpg', 'https://preview.redd.it/$name.jpg');

void main() {
  late Directory tmp;
  final hashes = <String, int>{};

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hobees_dupes');
    SavedStore.baseDir = () async => tmp;
    final d = await Db.db;
    await d.delete('downloads');
    await d.delete('saved');
    Downloaded.urls.value = const {};
    hashes.clear();
    DownloadDupes.hashOf = (u) async => hashes[u];
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> downloaded(String name, int hash, {String? savedPath}) =>
      Downloaded.mark(item(name).url, name, post: post(name), hash: hash, thumb: item(name).thumb, savedPath: savedPath);

  test('nothing downloaded before: no warning', () async {
    hashes[item('new').thumb] = 0x0F0F;
    expect(await DownloadDupes.find(item('new')), isNull);
  });

  test('the same file again', () async {
    await downloaded('a', 0x1234);
    final m = await DownloadDupes.find(item('a'));
    expect(m?.kind, DupKind.same);
    expect(m?.image, item('a').thumb);
    expect(m?.author, 'amy');
  });

  test('the same picture at another address is exact; a close one similar; a different one nothing', () async {
    await downloaded('a', 0);
    hashes[item('repost').thumb] = 0x3; // 2 bits apart
    expect((await DownloadDupes.find(item('repost')))?.kind, DupKind.exact);
    hashes[item('edit').thumb] = 0x7F; // 7 bits
    final e = await DownloadDupes.find(item('edit'));
    expect(e?.kind, DupKind.similar);
    expect(e?.bits, 7);
    hashes[item('other').thumb] = 0xFFFFF; // 20 bits
    expect(await DownloadDupes.find(item('other')), isNull);
  });

  test('the closest earlier download wins', () async {
    await downloaded('far', 0xFF);
    await downloaded('near', 0x1);
    hashes[item('x').thumb] = 0x0;
    expect((await DownloadDupes.find(item('x')))?.bits, 1);
  });

  test('a gallery file shows itself; one deleted from the gallery no longer counts', () async {
    final f = await SavedStore.newFile('jpg');
    await f.writeAsBytes([1]);
    await SavedStore.add(SavedItem(path: f.path, kind: 'image', savedAt: 1));
    await downloaded('kept', 0, savedPath: f.path);
    await downloaded('gone', 0, savedPath: '${tmp.path}/deleted.jpg');
    final k = await DownloadDupes.find(item('kept'));
    expect(k?.savedPath, f.path);
    expect(k?.image, f.path);
    expect(await DownloadDupes.find(item('gone')), isNull);
  });

  test('gallery files from before this update get a fingerprint and count too', () async {
    final f = await SavedStore.newFile('jpg');
    await f.writeAsBytes([9, 9, 9]);
    await SavedStore.add(SavedItem(path: f.path, kind: 'image', author: 'bob', subreddit: 'cats', savedAt: 1));
    final old = DownloadDupes.hashBytes;
    DownloadDupes.hashBytes = (b) async => b.length == 3 ? 0x10 : null;
    try {
      expect(await DownloadDupes.fillGallery(), 1);
      expect(await DownloadDupes.fillGallery(), 0, reason: 'done once');
    } finally {
      DownloadDupes.hashBytes = old;
    }
    hashes[item('y').thumb] = 0x10;
    final m = await DownloadDupes.find(item('y'));
    expect(m?.kind, DupKind.exact);
    expect(m?.author, 'bob');
    expect(m?.savedPath, f.path);
  });

  testWidgets('the comparison: download anyway, or cancel', (t) async {
    const d = DupMatch(kind: DupKind.similar, bits: 6, image: 'https://preview.redd.it/old.jpg', author: 'amy', subreddit: 'pics', created: 1700000000);
    bool? answer;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(onPressed: () async => answer = await confirmDuplicate(c, item('n'), post('n'), d), child: const Text('go')),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('dup-dialog')), findsOneWidget);
    expect(find.text('Looks like one downloaded before'), findsOneWidget);
    expect(find.textContaining('6 of 64'), findsOneWidget);
    expect(find.text('Saved to the phone gallery'), findsOneWidget);
    await t.tap(find.byKey(const Key('dup-download')));
    await t.pumpAndSettle();
    expect(answer, true);
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dup-cancel')));
    await t.pumpAndSettle();
    expect(answer, false);
  });

  testWidgets('several: one summary to skip those or download all', (t) async {
    const d = DupMatch(kind: DupKind.same, bits: 0);
    DupChoice? answer;
    var asked = false;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
            onPressed: () async {
              answer = await confirmDuplicates(c, [(item('a'), d), (item('b'), d)], 5);
              asked = true;
            },
            child: const Text('go')),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('2 of 5 look like earlier downloads'), findsOneWidget);
    await t.tap(find.byKey(const Key('dups-skip')));
    await t.pumpAndSettle();
    expect(answer, DupChoice.skip);
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dups-cancel')));
    await t.pumpAndSettle();
    expect(asked, true);
    expect(answer, isNull);
  });
}
