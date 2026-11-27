import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;
import 'app_lock.dart';
import 'background.dart' show BackgroundRefresh;
import 'db.dart';
import 'saved.dart';
import 'space.dart';
import 'start_lock.dart';

/// Settings → App lock → Panic profile (off by default, set up from your normal profile only).
///
/// On means a panic PIN is saved; then the start-up PIN screen ([StartLock]) opens a separate Hobees with its
/// own lists, history, gallery and logins when that PIN is typed. Turning it off can keep the panic profile's
/// data for later or delete all of it.
class PanicProfile {
  static const id = 1;
  static final on = ValueNotifier<bool>(false);

  // Test seams.
  @visibleForTesting
  static FlutterSecureStorage secure = const FlutterSecureStorage();
  /// Removes every setting whose key starts with the prefix (Android side; the settings API can't reach
  /// another profile's keys).
  @visibleForTesting
  static Future<void> Function(String prefix) dropPrefs =
      (prefix) => const MethodChannel('hobee/space').invokeMethod('dropPrefs', prefix);
  @visibleForTesting
  static Future<String> Function() dbDir = getDatabasesPath;
  @visibleForTesting
  static Future<Directory> Function() supportDir = getApplicationSupportDirectory;

  static Future<void> load() async {
    try {
      on.value = Space.id == 0 && await secure.read(key: StartLock.panicKey) != null;
    } catch (_) {
      on.value = false;
    }
  }

  /// Would [pin], as this profile's new app PIN, be the other profile's PIN? (The start-up screen must tell them
  /// apart.)
  static Future<bool> clashes(String pin) async {
    try {
      final h = await secure.read(key: Space.id == 0 ? StartLock.panicKey : StartLock.realKey);
      return h != null && verifyPin(pin, h);
    } catch (_) {
      return false;
    }
  }

  /// Saves [pin] as the panic PIN (turns it on, or changes it). Returns why not, or null when done.
  static Future<String?> setPin(String pin) async {
    if (Space.id != 0) return 'Not available here.';
    final mine = await secure.read(key: StartLock.realKey);
    if (mine == null) return 'Set an app PIN first.';
    if (verifyPin(pin, mine)) return "That's your app PIN. Pick a different one.";
    await secure.write(key: StartLock.panicKey, value: hashPin(pin));
    on.value = true;
    return null;
  }

  /// Turns it off. With [delete], everything the panic profile saved goes too; otherwise it's kept and comes
  /// back when it's turned on again.
  static Future<void> turnOff({required bool delete}) async {
    await secure.delete(key: StartLock.panicKey);
    on.value = false;
    try {
      await BackgroundRefresh.stop(id); // its background refresh stops too
    } catch (_) {}
    if (delete) await wipe();
  }

  /// Deletes all of the panic profile's data: settings (search history included), database, Hobees gallery,
  /// crash log, logins and PIN. Your own profile isn't touched.
  static Future<void> wipe() async {
    final prefix = Space.keyPrefix(id);
    for (final k in (await secure.readAll()).keys.where((k) => k.startsWith(prefix)).toList()) {
      await secure.delete(key: k);
    }
    await dropPrefs(Space.prefsPrefix(id));
    final db = File(p.join(await dbDir(), Space.dbFile(Db.fileName, id)));
    for (final f in [db, File('${db.path}-journal'), File('${db.path}-wal'), File('${db.path}-shm')]) {
      if (await f.exists()) await f.delete();
    }
    final gallery = Directory('${(await SavedStore.baseDir()).path}/${Space.galleryDirOf(id)}');
    if (await gallery.exists()) await gallery.delete(recursive: true);
    final crash = File('${(await supportDir()).path}/${Space.crashFileOf(id)}');
    if (await crash.exists()) await crash.delete();
  }
}
