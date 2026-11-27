import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/app_lock.dart';
import 'package:hobee/app_lock_ui.dart';
import 'package:hobee/db.dart';
import 'package:hobee/panic_profile.dart';
import 'package:hobee/saved.dart';
import 'package:hobee/space.dart';
import 'package:hobee/start_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late List<String> dropped;
  const store = FlutterSecureStorage();

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppLock.debugReset();
    AppLock.pinStore = PinStore();
    PanicProfile.on.value = false;
    tmp = await Directory.systemTemp.createTemp('hobees_panic');
    dropped = [];
    PanicProfile.dropPrefs = (p) async => dropped.add(p);
    PanicProfile.dbDir = () async => tmp.path;
    PanicProfile.supportDir = () async => tmp;
    SavedStore.baseDir = () async => tmp;
  });

  tearDown(() async {
    Space.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('needs your app PIN first, and a different PIN', () async {
    expect(await PanicProfile.setPin('2222'), isNotNull);
    expect(PanicProfile.on.value, isFalse);
    await AppLock.setPin('1111');
    expect(await PanicProfile.setPin('1111'), contains('your app PIN'));
    expect(PanicProfile.on.value, isFalse);
    expect(await PanicProfile.setPin('2222'), isNull);
    expect(PanicProfile.on.value, isTrue);
  });

  test('once on, the start-up screen asks and each PIN opens its profile', () async {
    await AppLock.setPin('1111');
    await PanicProfile.setPin('2222');
    expect(await StartLock.isOn(), isTrue);
    expect(await StartLock.profileFor('1111'), 0);
    expect(await StartLock.profileFor('2222'), 1);
    await PanicProfile.load();
    expect(PanicProfile.on.value, isTrue);
  });

  test("changing either profile's PIN to the other's is refused", () async {
    await AppLock.setPin('1111');
    await PanicProfile.setPin('2222');
    expect(await PanicProfile.clashes('2222'), isTrue);
    expect(await PanicProfile.clashes('3333'), isFalse);
    Space.open(1);
    expect(await PanicProfile.clashes('1111'), isTrue, reason: 'the panic profile may not take your PIN');
    expect(await PanicProfile.setPin('4444'), isNotNull, reason: 'set up from your profile only');
  });

  Future<List<File>> files() async {
    final real = [
      File('${tmp.path}/${Db.fileName}'),
      File('${tmp.path}/gallery/a.jpg'),
      File('${tmp.path}/crash.log'),
    ];
    final panic = [
      File('${tmp.path}/${Space.dbFile(Db.fileName, 1)}'),
      File('${tmp.path}/gallery_p1/b.jpg'),
      File('${tmp.path}/crash_p1.log'),
    ];
    for (final f in [...real, ...panic]) {
      await f.create(recursive: true);
    }
    return [...real, ...panic];
  }

  test('off and kept: only the panic PIN goes, its data stays for later', () async {
    await AppLock.setPin('1111');
    await PanicProfile.setPin('2222');
    await store.write(key: 'p1.username', value: 'x');
    final fs = await files();
    await PanicProfile.turnOff(delete: false);
    expect(PanicProfile.on.value, isFalse);
    expect(await StartLock.isOn(), isFalse);
    expect(await store.read(key: 'p1.username'), 'x');
    expect([for (final f in fs) await f.exists()], everyElement(isTrue));
    expect(dropped, isEmpty);
  });

  test('off and deleted: every panic store goes, yours stay', () async {
    await AppLock.setPin('1111');
    await PanicProfile.setPin('2222');
    await store.write(key: 'p1.username', value: 'x');
    await store.write(key: 'username', value: 'me');
    final fs = await files();
    await PanicProfile.turnOff(delete: true);
    expect((await store.readAll()).keys.where((k) => k.startsWith('p1.')), isEmpty);
    expect(await store.read(key: 'username'), 'me');
    expect(await store.read(key: 'appLockPin'), isNotNull);
    expect(dropped, ['hobeesP1.']);
    expect([for (final f in fs.take(3)) await f.exists()], everyElement(isTrue), reason: 'your database, gallery, crash log');
    expect([for (final f in fs.skip(3)) await f.exists()], everyElement(isFalse));
    expect(await Directory('${tmp.path}/gallery_p1').exists(), isFalse);
  });

  Widget app() => const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AppLockSettings())));

  testWidgets('the switch needs an app PIN, and shows only in your profile', (t) async {
    await t.pumpWidget(app());
    expect(t.widget<SwitchListTile>(find.byKey(const Key('lock-panic'))).onChanged, isNull);
    expect(find.text('Needs an app PIN first.'), findsOneWidget);
    await t.runAsync(() => AppLock.setPin('1111'));
    await t.pump();
    expect(t.widget<SwitchListTile>(find.byKey(const Key('lock-panic'))).onChanged, isNotNull);
    Space.open(1);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app());
    expect(find.byKey(const Key('lock-panic')), findsNothing);
  });

  testWidgets("while it's on, your app PIN can't be removed", (t) async {
    await t.runAsync(() async {
      await AppLock.setPin('1111');
      await PanicProfile.setPin('2222');
    });
    await t.pumpWidget(app());
    expect(find.byKey(const Key('lock-panic-pin')), findsOneWidget);
    await t.tap(find.byKey(const Key('lock-pin-remove')));
    await t.pump();
    expect(find.textContaining('Turn the panic profile off first'), findsOneWidget);
    expect(AppLock.hasPin.value, isTrue);
    expect(AppLock.locked.value, isFalse, reason: 'not even asked to unlock');
  });
}
