import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'following.dart';
import 'pace_log.dart';
import 'follows.dart';
import 'net_guard.dart';
import 'space.dart';
import 'start_lock.dart';

/// Settings → Background refresh: keeps the active Following profile up to date while the app is closed,
/// using Android's WorkManager. Android picks the exact time (at least the chosen interval apart, later in
/// Doze), so this keeps lists fresh but isn't live. Off by default.
class BackgroundRefresh {
  static const task = 'hobees.following.refresh';
  /// Each profile has its own task, which opens only that profile's data (your profile keeps the old name).
  static String taskFor(int profile) => profile == 0 ? task : '$task.p$profile';

  // Test seams.
  @visibleForTesting
  static Future<void> Function(String name, Map<String, dynamic> input, Duration every, Constraints c) register =
      (name, input, every, c) => Workmanager().registerPeriodicTask(name, task,
          frequency: every, constraints: c, inputData: input, existingWorkPolicy: ExistingPeriodicWorkPolicy.update);
  @visibleForTesting
  static Future<void> Function(String name) cancel = (name) => Workmanager().cancelByUniqueName(name);
  static final enabled = ValueNotifier<bool>(false);
  static final wifiOnly = ValueNotifier<bool>(true);
  static final chargingOnly = ValueNotifier<bool>(false);
  static final everyMinutes = ValueNotifier<int>(60);
  static const choices = [30, 60, 120, 240];

  /// Longest a background run keeps fetching (WorkManager stops workers after about 10 minutes).
  static const maxRun = Duration(minutes: 8);

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    enabled.value = sp.getBool('bgRefresh') ?? false;
    wifiOnly.value = sp.getBool('bgWifiOnly') ?? true;
    chargingOnly.value = sp.getBool('bgCharging') ?? false;
    final m = sp.getInt('bgEvery') ?? 60;
    everyMinutes.value = choices.contains(m) ? m : 60;
    for (final (n, k) in [(enabled, 'bgRefresh'), (wifiOnly, 'bgWifiOnly'), (chargingOnly, 'bgCharging')]) {
      n.addListener(() => sp.setBool(k, n.value).then((_) => schedule()));
    }
    everyMinutes.addListener(() => sp.setInt('bgEvery', everyMinutes.value).then((_) => schedule()));
    await Workmanager().initialize(backgroundDispatcher);
    await schedule();
  }

  /// Registers (or replaces) the periodic task with the current settings, or cancels it when off.
  static Future<void> schedule() async {
    final name = taskFor(Space.id);
    try {
      if (!enabled.value) {
        await cancel(name);
        return;
      }
      await register(
        name,
        {'space': Space.id},
        Duration(minutes: everyMinutes.value),
        Constraints(
          networkType: wifiOnly.value ? NetworkType.unmetered : NetworkType.connected,
          requiresCharging: chargingOnly.value,
          requiresBatteryNotLow: true,
        ),
      );
    } catch (e) {
      debugPrint('background refresh schedule failed: $e');
    }
  }

  /// Stops profile [profile]'s background refresh (the panic profile being turned off).
  static Future<void> stop(int profile) => cancel(taskFor(profile));

  /// In the background task, before anything is read: opens the profile the task belongs to. False when it's
  /// the panic profile and that's off (its task is cancelled then).
  static Future<bool> openProfile(Map<String, dynamic>? input) async {
    final v = input?['space'];
    final id = v is int ? v : 0;
    if (id != 0 && !await StartLock.isOn()) {
      await cancel(taskFor(id));
      return false;
    }
    Space.open(id);
    return true;
  }

  /// One background pass: continue (or start) the active profile's refresh round for up to [maxRun].
  static Future<bool> run({DateTime Function() now = DateTime.now}) async {
    await FollowStore.load();
    final pid = FollowStore.active.value;
    if (pid == null) return true;
    final src = followingKey(pid);
    final end = now().add(maxRun);
    var first = true;
    while (now().isBefore(end)) {
      final n = await Following.fetchMore(src, fromStart: first);
      first = false;
      if (n < 0 || !Following.refreshing(src)) break;
    }
    return true;
  }
}

/// WorkManager entry point (runs in a background isolate, without the UI).
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    DartPluginRegistrant.ensureInitialized();
    PaceLog.inBackgroundTask = true; // its requests show as 'background' in the archive pace log
    try {
      if (!await BackgroundRefresh.openProfile(input)) return true;
      // Wi-Fi safety: only on the connection last seen trusted (or mobile data if allowed). Never reads the
      // Wi-Fi name in the background, so no 'location all the time' permission.
      if (!await NetGuard.backgroundOk()) return true;
      return await BackgroundRefresh.run();
    } catch (e) {
      debugPrint('background refresh failed: $e');
      return true; // don't let WorkManager retry in a tight loop; the next period tries again
    }
  });
}
