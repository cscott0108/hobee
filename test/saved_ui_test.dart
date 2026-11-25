import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/saved.dart';
import 'package:hobee/saved_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  final calls = <MethodCall>[];
  const media = MethodChannel('hobee/media');

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
  });

  Future<void> settle(WidgetTester t) async {
    // Each await on real file / database work only moves on between pumps, so give it plenty of rounds.
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
  }

  /// Three saved items (newest first: c, b, a) and the gallery screen on top.
  Future<List<SavedItem>> open(WidgetTester t) async {
    final saved = await t.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('hobees_ui');
      SavedStore.baseDir = () async => tmp;
      await (await Db.db).delete('saved');
      final out = <SavedItem>[];
      for (final (k, at) in [('image', 1000), ('video', 2000), ('image', 3000)]) {
        final f = await SavedStore.newFile(k == 'video' ? 'mp4' : 'png');
        await f.writeAsBytes([1, 2, 3]);
        final it = SavedItem(path: f.path, kind: k, savedAt: at, permalink: '/r/x/comments/$at');
        out.add(SavedItem.fromRow({...it.toRow(), 'id': await SavedStore.add(it)}));
      }
      return out.reversed.toList();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(media, (c) async {
      calls.add(c);
      return switch (c.method) { 'sdk' => 34, 'save' => 'content://media/1', 'zip' => 'content://downloads/1', _ => null };
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(media, null);
      await t.runAsync(() => tmp.delete(recursive: true));
    });
    await t.pumpWidget(const MaterialApp(home: SavedGalleryScreen()));
    await settle(t);
    return saved!;
  }

  testWidgets('shows what was saved, newest first', (t) async {
    await open(t);
    expect(find.text('Hobees gallery · 3'), findsOneWidget);
    expect(find.byKey(const Key('saved-tile-2')), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget, reason: 'the video is marked');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('long-press selects, tap adds more, delete removes files and rows', (t) async {
    final s = await open(t);
    await t.longPress(find.byKey(const Key('saved-tile-0')));
    await t.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await t.tap(find.byKey(const Key('saved-tile-1')));
    await t.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await t.tap(find.byKey(const Key('sel-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('delete-go')));
    await settle(t);
    expect(find.text('Hobees gallery · 1'), findsOneWidget);
    final left = await t.runAsync(() async => [await File(s[0].path).exists(), await File(s[1].path).exists(), await File(s[2].path).exists()]);
    expect(left, [false, false, true]);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('export several as individual files to the phone gallery', (t) async {
    final s = await open(t);
    await t.longPress(find.byKey(const Key('saved-tile-0')));
    await t.pump();
    await t.tap(find.byKey(const Key('select-all')));
    await t.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await t.tap(find.byKey(const Key('sel-export')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('export-go'))); // individual files is the default
    await settle(t);
    final saves = calls.where((c) => c.method == 'save').toList();
    expect(saves.map((c) => c.arguments['path']), [for (final it in s) it.path]);
    expect(find.text('Hobees gallery · 3'), findsOneWidget, reason: 'kept in Hobees unless asked to remove');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('export several as one zip and remove them from Hobees', (t) async {
    final s = await open(t);
    await t.longPress(find.byKey(const Key('saved-tile-0')));
    await t.tap(find.byKey(const Key('saved-tile-2')));
    await t.pump();
    await t.tap(find.byKey(const Key('sel-export')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('export-zip')));
    await t.tap(find.byKey(const Key('export-remove')));
    await t.pump();
    await t.tap(find.byKey(const Key('export-go')));
    await settle(t);
    final z = calls.singleWhere((c) => c.method == 'zip');
    expect(z.arguments['paths'], [s[0].path, s[2].path]);
    expect(calls.where((c) => c.method == 'save'), isEmpty);
    expect(find.text('Hobees gallery · 1'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the top-bar gallery button opens the Hobees gallery', (t) async {
    await t.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('hobees_ui');
      SavedStore.baseDir = () async => tmp;
      await (await Db.db).delete('saved');
    });
    addTearDown(() => t.runAsync(() => tmp.delete(recursive: true)));
    await t.pumpWidget(MaterialApp(home: Scaffold(appBar: AppBar(actions: const [GalleryButton()]))));
    await t.tap(find.byKey(const Key('gallery-button')));
    await t.pump(const Duration(milliseconds: 400)); // page transition (the loading spinner never settles)
    await settle(t);
    expect(find.byType(SavedGalleryScreen), findsOneWidget);
    expect(find.text('Hobees gallery'), findsOneWidget, reason: 'the gallery page is on top');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('menu: Export all exports everything without selecting', (t) async {
    final s = await open(t);
    await t.tap(find.byKey(const Key('gallery-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('menu-export-all')));
    await t.pumpAndSettle();
    expect(find.text('Export 3 items'), findsOneWidget);
    await t.tap(find.byKey(const Key('export-go')));
    await settle(t);
    expect(calls.where((c) => c.method == 'save').map((c) => c.arguments['path']), [for (final it in s) it.path]);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('menu: Back up writes one Hobees_backup zip with the list and every file', (t) async {
    final s = await open(t);
    await t.tap(find.byKey(const Key('gallery-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('menu-backup')));
    await t.pumpAndSettle();
    expect(find.textContaining('app lock doesn'), findsOneWidget, reason: 'warns that the zip is outside the lock');
    await t.tap(find.byKey(const Key('backup-go')));
    await settle(t);
    final z = calls.singleWhere((c) => c.method == 'zip');
    expect(z.arguments['name'] as String, startsWith('Hobees_backup_'));
    expect((z.arguments['names'] as List).first, 'hobees-gallery.json');
    expect((z.arguments['paths'] as List).skip(1), [for (final it in s) it.path]);
    await t.pumpWidget(const SizedBox());
  });
}
