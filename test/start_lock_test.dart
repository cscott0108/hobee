import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/app_lock.dart';
import 'package:hobee/space.dart';
import 'package:hobee/start_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Map<String, String> store;
  late DateTime now;
  late List<String> reads;

  setUp(() {
    StartLock.debugReset();
    AppLock.debugReset();
    store = {};
    reads = [];
    now = DateTime(2026, 11, 26, 12);
    StartLock.read = (k) async {
      reads.add(k);
      return store[k];
    };
    StartLock.clock = () => now;
  });

  void setPins({String? real, String? panic}) {
    if (real != null) store[StartLock.realKey] = hashPin(real, iterations: 10);
    if (panic != null) store[StartLock.panicKey] = hashPin(panic, iterations: 10);
  }

  test('it reads the same keys each profile keeps its app PIN under', () {
    expect(StartLock.realKey, Space.key('appLockPin'));
    Space.open(1);
    expect(StartLock.panicKey, Space.key('appLockPin'));
    Space.debugReset();
  });

  test('off unless both PINs exist, and it reads only encrypted storage', () async {
    expect(await StartLock.isOn(), isFalse);
    setPins(real: '1111');
    expect(await StartLock.isOn(), isFalse, reason: 'app PIN alone: start as before');
    store.clear();
    setPins(panic: '2222');
    expect(await StartLock.isOn(), isFalse, reason: 'no way back to your profile without your PIN');
    setPins(real: '1111');
    expect(await StartLock.isOn(), isTrue);
    expect(reads.toSet(), {StartLock.realKey, StartLock.panicKey});
  });

  test('your PIN opens your profile, the panic PIN the panic profile, a wrong one nothing', () async {
    setPins(real: '1111', panic: '2222');
    expect(await StartLock.profileFor('1111'), 0);
    expect(await StartLock.profileFor('2222'), 1);
    expect(await StartLock.profileFor('3333'), isNull);
  });

  test('five wrong PINs wait 30 s, even for the right one', () async {
    setPins(real: '1111', panic: '2222');
    for (var i = 0; i < 5; i++) {
      expect(await StartLock.profileFor('0000'), isNull);
    }
    expect(StartLock.wait, 30);
    expect(await StartLock.profileFor('2222'), isNull);
    now = now.add(const Duration(seconds: 31));
    expect(await StartLock.profileFor('2222'), 1);
  });

  testWidgets('the screen picks a profile only after a right PIN', (t) async {
    setPins(real: '1111', panic: '2222');
    final picked = <int>[];
    await t.pumpWidget(MaterialApp(home: StartLockScreen(onPicked: picked.add)));
    expect(find.text('Unlock Hobees'), findsOneWidget);
    expect(find.textContaining('panic', findRichText: true), findsNothing);
    Future<void> enter(String pin) async {
      for (final d in pin.split('')) {
        await t.tap(find.byKey(Key('pin-$d')));
      }
      await t.tap(find.byKey(const Key('pin-ok')));
      await t.pump();
      await t.pump();
    }

    await enter('3333');
    expect(picked, isEmpty);
    expect(find.text('Wrong PIN'), findsOneWidget);
    await enter('2222');
    expect(picked, [1]);
    expect(find.byKey(const Key('start-pinpad')), findsNothing);
  });

  group('app lock after the start-up PIN', () {
    setUp(() => SharedPreferences.setMockInitialValues({'lockEnabled': true, 'lockedProfiles': ['3']}));

    test("doesn't ask a second time, and locked lists are open", () async {
      AppLock.deviceSupported = () async => true;
      AppLock.unlockedAtStart = true;
      await AppLock.load();
      expect(AppLock.locked.value, isFalse);
      expect(await AppLock.allowProfile(3, 'x'), isTrue);
    });

    test('without it, the app lock asks on start as before', () async {
      await AppLock.load();
      expect(AppLock.locked.value, isTrue);
    });
  });
}
