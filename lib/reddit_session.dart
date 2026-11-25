import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Thrown when Reddit no longer accepts the saved session (401/403). The session is marked ended and the app
/// carries on without login.
class SessionEndedException implements Exception {
  final int status;
  const SessionEndedException(this.status);
  @override
  String toString() => 'Reddit session ended (HTTP $status). Log in again in Settings → Reddit account.';
}

/// Your own Reddit website session (Phase 7, opt-in). You log in on Reddit's own page inside Hobees; Hobees keeps
/// only the `reddit_session` cookie Reddit sets, in encrypted storage, never your password. Requests with it go to
/// www.reddit.com's JSON pages and identify as Hobees (no browser disguise).
class RedditSession {
  static const _cookieKey = 'redditSessionCookie';
  static const _userKey = 'redditSessionUser';
  static const _warnedKey = 'redditSessionWarned';
  static const cookieName = 'reddit_session';
  static const _web = MethodChannel('hobee/web');

  /// Test seams.
  static Future<String?> Function(String key) read = (k) => const FlutterSecureStorage().read(key: k);
  static Future<void> Function(String key, String? value) write = (k, v) async =>
      v == null ? const FlutterSecureStorage().delete(key: k) : const FlutterSecureStorage().write(key: k, value: v);
  static http.Client Function() client = http.Client.new;

  static final cookie = ValueNotifier<String?>(null);
  static final username = ValueNotifier<String?>(null);
  /// Reddit refused the session; it stays saved (so the message can say so) until you log in again or out.
  static final ended = ValueNotifier<bool>(false);

  static bool get active => cookie.value != null && !ended.value;

  /// Same app id as every other Hobees request; with the account name once known (Reddit's API rules).
  static String get userAgent => 'android:io.github.cscott0108.hobees:v1.0 (by /u/${username.value ?? 'unknown'})';

  static Future<void> load() async {
    cookie.value = await read(_cookieKey);
    username.value = await read(_userKey);
    ended.value = false;
  }

  /// The warning was shown and accepted (once).
  static Future<bool> warned() async => await read(_warnedKey) == '1';
  static Future<void> setWarned() => write(_warnedKey, '1');

  /// The `reddit_session` value from a Cookie header string ("a=1; reddit_session=xyz; b=2"), or null.
  static String? pick(String? cookieHeader) {
    if (cookieHeader == null) return null;
    for (final part in cookieHeader.split(';')) {
      final i = part.indexOf('=');
      if (i < 0) continue;
      if (part.substring(0, i).trim() == cookieName) {
        final v = part.substring(i + 1).trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }

  /// The cookies the login page set for reddit.com (read on the Android side).
  static Future<String?> webCookies() async {
    try {
      return await _web.invokeMethod<String>('cookies', {'url': 'https://www.reddit.com'});
    } catch (_) {
      return null;
    }
  }

  /// Saves a fresh session and looks up the account name.
  static Future<void> save(String value) async {
    cookie.value = value;
    ended.value = false;
    await write(_cookieKey, value);
    try {
      final me = await getJson('/api/me');
      final name = (me['data'] is Map ? me['data']['name'] : me['name']) as String?;
      if (name != null) {
        username.value = name;
        await write(_userKey, name);
      }
    } catch (_) {}
  }

  static Future<void> logout() async {
    cookie.value = null;
    username.value = null;
    ended.value = false;
    await write(_cookieKey, null);
    await write(_userKey, null);
  }

  /// GET https://www.reddit.com[path].json with the session cookie and the Hobees User-Agent.
  static Future<Map<String, dynamic>> getJson(String path, [Map<String, String>? q]) async {
    final c = cookie.value;
    if (c == null) throw const SessionEndedException(401);
    final p = path.endsWith('.json') ? path : '$path.json';
    final cl = client();
    try {
      final r = await cl.get(Uri.https('www.reddit.com', p, {'raw_json': '1', ...?q}),
          headers: {'Cookie': '$cookieName=$c', 'User-Agent': userAgent}).timeout(const Duration(seconds: 25));
      if (r.statusCode == 401 || r.statusCode == 403) {
        ended.value = true;
        throw SessionEndedException(r.statusCode);
      }
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode} for $path');
      final j = jsonDecode(r.body);
      if (j is! Map<String, dynamic>) throw Exception('Unexpected response for $path');
      return j;
    } finally {
      cl.close();
    }
  }

  /// Every subreddit you subscribe to on Reddit (user profiles excluded), A–Z.
  static Future<List<String>> subscriptions() async {
    final out = <String>{};
    String? after;
    for (var page = 0; page < 20; page++) {
      final j = await getJson('/subreddits/mine/subscriber', {'limit': '100', 'after': ?after});
      final data = j['data'] as Map<String, dynamic>? ?? const {};
      for (final c in (data['children'] as List? ?? const [])) {
        final d = (c as Map)['data'] as Map? ?? const {};
        final name = d['display_name'] as String?;
        if (name != null && !name.startsWith('u_') && d['subreddit_type'] != 'user') out.add(name);
      }
      after = data['after'] as String?;
      if (after == null) break;
    }
    return out.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }
}
