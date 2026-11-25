import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_lock.dart';

/// Settings -> Hide Hobees: send Hobees to the background (and lock it, when the app lock is on) when the phone
/// is laid face down, or when it's covered and dark (pocket, hand over it). Android reads the sensors only while
/// Hobees is on screen; nothing is recorded.
class HideGestures {
  static const _ch = MethodChannel('hobee/hide');
  static final flip = ValueNotifier<bool>(false);
  static final dark = ValueNotifier<bool>(false);

  /// How long the phone must be face down / covered and dark before Hobees hides, in tenths of a second (1–10).
  static final flipTenths = ValueNotifier<int>(5);
  static final darkTenths = ValueNotifier<int>(10);

  /// Which sensors this phone has (accelerometer, light, proximity).
  static final sensors = ValueNotifier<Map<String, bool>>(const {});

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    flip.value = sp.getBool('hideFlip') ?? false;
    dark.value = sp.getBool('hideDark') ?? false;
    flipTenths.value = (sp.getInt('hideFlipTenths') ?? 5).clamp(1, 10);
    darkTenths.value = (sp.getInt('hideDarkTenths') ?? 10).clamp(1, 10);
    _ch.setMethodCallHandler((c) async {
      if (c.method == 'hide') await hide();
    });
    try {
      final m = await _ch.invokeMapMethod<String, bool>('sensors');
      if (m != null) sensors.value = m;
    } catch (_) {}
    await _apply();
    flip.addListener(() => sp.setBool('hideFlip', flip.value).then((_) => _apply()));
    dark.addListener(() => sp.setBool('hideDark', dark.value).then((_) => _apply()));
    flipTenths.addListener(() => sp.setInt('hideFlipTenths', flipTenths.value).then((_) => _apply()));
    darkTenths.addListener(() => sp.setInt('hideDarkTenths', darkTenths.value).then((_) => _apply()));
  }

  static Future<void> _apply() async {
    try {
      await _ch.invokeMethod('configure',
          {'flip': flip.value, 'dark': dark.value, 'flipMs': flipTenths.value * 100, 'darkMs': darkTenths.value * 100});
    } catch (_) {}
  }

  /// Android has sent Hobees to the background: lock it (if the app lock is on, or a locked list is on screen).
  static Future<void> hide() async => AppLock.lockNow();
}
