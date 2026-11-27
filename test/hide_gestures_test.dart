import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/app_lock.dart';
import 'package:hobee/hide_gestures.dart';

void main() {
  setUp(AppLock.debugReset);

  tearDown(AppLock.debugReset);

  test('hiding locks the app right away when the lock is on', () async {
    AppLock.enabled.value = true;
    expect(AppLock.locked.value, isFalse);
    await HideGestures.hide();
    expect(AppLock.locked.value, isTrue);
  });

  test('with the lock off nothing locks, except a locked list on screen', () async {
    AppLock.enabled.value = false;
    await HideGestures.hide();
    expect(AppLock.locked.value, isFalse);

    AppLock.lockedProfiles.value = {7};
    AppLock.viewingProfile = () => 7;
    await HideGestures.hide();
    expect(AppLock.locked.value, isTrue, reason: 'the locked list on screen needs its unlock again');
    AppLock.viewingProfile = () => null;
    AppLock.lockedProfiles.value = const {};
  });
}
