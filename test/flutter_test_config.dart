import 'dart:async';
import 'dart:io';
import 'package:hobee/db.dart';

/// Runs before every test file. Each test file runs in its own process, and they run side by side, so each
/// gets its own SQLite file instead of all locking one shared hobee.db ("database is locked").
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Db.fileName = 'hobee_test_$pid.db';
  await testMain();
  try {
    final f = File('${Directory.current.path}/.dart_tool/sqflite_common_ffi/databases/${Db.fileName}');
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
