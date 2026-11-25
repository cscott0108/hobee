import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/app_lock.dart';
import 'package:hobee/hide_gestures.dart';

void main() {
  var moved = 0;

  setUp(() {
    AppLock.debugReset();
    moved = 0;
    HideGestures.moveToBack = () async => moved++;
  });

  tearDown(AppLock.debugReset);

  test('hiding locks the app when the lock is on, then goes to the background', () async {
    AppLock.enabled.value = true;
    expect(AppLock.locked.value, isFalse);
    await HideGestures.hide();
    expect(AppLock.locked.value, isTrue);
    expect(moved, 1);
  });

  test('with the lock off it only hides, except on a locked list, which it covers', () async {
    AppLock.enabled.value = false;
    await HideGestures.hide();
    expect(AppLock.locked.value, isFalse);
    expect(moved, 1);

    AppLock.lockedProfiles.value = {7};
    AppLock.viewingProfile = () => 7;
    await HideGestures.hide();
    expect(AppLock.locked.value, isTrue, reason: 'the locked list on screen needs its unlock again');
    expect(moved, 2);
    AppLock.viewingProfile = () => null;
    AppLock.lockedProfiles.value = const {};
  });
}
