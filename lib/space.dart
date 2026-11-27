import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which profile's data is open: 0 is your normal profile, 1 the panic profile.
///
/// Each profile has its own settings, database, Hobees gallery, saved logins and crash log. Profile 0 keeps
/// the names Hobees always used, so nothing moves for it. The profile is picked once at startup, before anything
/// is loaded; switching restarts the app.
class Space {
  static int _id = 0;

  static int get id => _id;

  /// Settings key prefix of profile [id]. The panic profile's doesn't start with `flutter.`, so profile 0's
  /// settings never list its keys.
  static String prefsPrefix(int id) => id == 0 ? 'flutter.' : 'hobeesP$id.';

  /// Opens profile [id]. Call before the first `SharedPreferences.getInstance()`.
  static void open(int id) {
    _id = id;
    if (id != 0) SharedPreferences.setPrefix(prefsPrefix(id));
  }

  /// Back to profile 0 (tests only; settings keep whatever prefix was set).
  @visibleForTesting
  static void debugReset() => _id = 0;

  /// The open profile's database file, from Hobees' own [base] name (`hobee.db` → `hobee_p1.db`).
  static String dbFile(String base) => _id == 0 ? base : base.replaceFirst(RegExp(r'(\.db)?$'), '_p$_id.db');

  /// The open profile's Hobees gallery folder name.
  static String get galleryDir => _id == 0 ? 'gallery' : 'gallery_p$_id';

  /// The open profile's crash log file name.
  static String get crashFile => _id == 0 ? 'crash.log' : 'crash_p$_id.log';

  /// The open profile's encrypted-storage key for [k] (logins, the app PIN).
  static String key(String k) => _id == 0 ? k : 'p$_id.$k';
}
