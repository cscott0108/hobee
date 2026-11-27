import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'app_lock.dart';
import 'app_lock_ui.dart' show PinPad;
import 'space.dart';

/// The panic profile's start-up choice.
///
/// The panic profile is on while both PINs exist: your app PIN and the panic PIN (the panic profile's own app
/// PIN). Both hashes are read straight from encrypted storage, outside either profile, so this runs before any
/// settings, posts or logins are read. Your PIN opens your profile (0), the panic PIN the panic profile (1).
class StartLock {
  static const realKey = 'appLockPin';
  static const panicKey = 'p1.appLockPin';
  /// Set just before a switch restarts the app: `<profile>:<ms since epoch>`. Only Hobees can write it (its own
  /// encrypted storage), so the restart may open that profile without asking again.
  static const switchKey = 'switchTo';
  static const switchFresh = Duration(seconds: 30);

  /// Test seams.
  @visibleForTesting
  static Future<String?> Function(String key) read = (k) => const FlutterSecureStorage().read(key: k);
  @visibleForTesting
  static Future<void> Function(String key, String? value) write = (k, v) async =>
      v == null ? const FlutterSecureStorage().delete(key: k) : const FlutterSecureStorage().write(key: k, value: v);
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;
  /// Restarts the app process (Android side).
  @visibleForTesting
  static Future<void> Function() restart = () => const MethodChannel('hobee/space').invokeMethod('restart');

  static int _wrong = 0;
  static DateTime? _waitUntil;

  /// Is the start-up PIN screen needed?
  static Future<bool> isOn() async => await read(panicKey) != null && await read(realKey) != null;

  /// Seconds to wait before the next try (after 5 wrong ones), 0 when free.
  static int get wait {
    final w = _waitUntil;
    if (w == null) return 0;
    final s = w.difference(clock()).inSeconds;
    return s > 0 ? s : 0;
  }

  /// The profile [pin] opens, or null (wrong PIN, or waiting after too many tries).
  static Future<int?> profileFor(String pin) async {
    if (wait > 0) return null;
    for (final (id, key) in const [(0, realKey), (1, panicKey)]) {
      final stored = await read(key);
      if (stored != null && verifyPin(pin, stored)) {
        _wrong = 0;
        _waitUntil = null;
        return id;
      }
    }
    if (++_wrong >= 5) {
      _wrong = 0;
      _waitUntil = clock().add(const Duration(seconds: 30));
    }
    return null;
  }

  /// The other profile [pin] opens, from inside a profile; null when it's this profile's PIN, wrong, or the panic
  /// profile is off.
  static Future<int?> otherProfileFor(String pin) async {
    final other = Space.id == 0 ? 1 : 0;
    if (!await isOn()) return null;
    final stored = await read(other == 0 ? realKey : panicKey);
    return stored != null && verifyPin(pin, stored) ? other : null;
  }

  /// Restarts Hobees into profile [id] (the PIN for it was just typed).
  static Future<void> switchTo(int id) async {
    await write(switchKey, '$id:${clock().millisecondsSinceEpoch}');
    await restart();
  }

  /// At start-up: the profile a switch just asked for, if any (used once; older than [switchFresh] is ignored).
  static Future<int?> takeSwitch() async {
    final v = await read(switchKey);
    if (v == null) return null;
    await write(switchKey, null);
    final parts = v.split(':');
    final id = parts.length == 2 ? int.tryParse(parts[0]) : null;
    final at = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (id == null || at == null || (id != 0 && id != 1)) return null;
    final age = clock().difference(DateTime.fromMillisecondsSinceEpoch(at));
    return age.isNegative || age > switchFresh ? null : id;
  }

  /// Shows the PIN screen as the whole app until a PIN picks a profile; returns that profile.
  static Future<int> ask(ThemeData light, ThemeData dark) {
    final c = Completer<int>();
    runApp(MaterialApp(
      title: 'Hobees',
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      home: StartLockScreen(onPicked: c.complete),
    ));
    return c.future;
  }

  @visibleForTesting
  static void debugReset() {
    _wrong = 0;
    _waitUntil = null;
  }
}

/// "Unlock Hobees" with the PIN pad, shown before anything else loads. It looks like the app lock's PIN pad and
/// says nothing about profiles.
class StartLockScreen extends StatefulWidget {
  final void Function(int profile) onPicked;
  const StartLockScreen({super.key, required this.onPicked});
  @override
  State<StartLockScreen> createState() => _StartLockScreenState();
}

class _StartLockScreenState extends State<StartLockScreen> {
  String? msg;
  bool done = false;

  Future<bool> _pin(String p) async {
    if (done) return true;
    final id = await StartLock.profileFor(p);
    if (!mounted) return id != null;
    if (id == null) {
      final w = StartLock.wait;
      setState(() => msg = w > 0 ? 'Too many tries. Wait $w s.' : 'Wrong PIN');
      return false;
    }
    setState(() {
      done = true;
      msg = null;
    });
    widget.onPicked(id);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: const Key('start-lock'),
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline, size: 56, color: cs.primary),
              const SizedBox(height: 12),
              Text('Unlock Hobees', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (done) const CircularProgressIndicator() else PinPad(key: const Key('start-pinpad'), onDone: _pin),
              if (msg != null) ...[
                const SizedBox(height: 12),
                Text(msg!, key: const Key('start-msg'), style: TextStyle(color: cs.error), textAlign: TextAlign.center),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
