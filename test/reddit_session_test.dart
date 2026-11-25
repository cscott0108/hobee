import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hobee/reddit_session.dart';

void main() {
  final store = <String, String>{};
  final seen = <http.Request>[];
  var status = 200;

  setUp(() {
    store.clear();
    seen.clear();
    status = 200;
    RedditSession.read = (k) async => store[k];
    RedditSession.write = (k, v) async {
      if (v == null) {
        store.remove(k);
      } else {
        store[k] = v;
      }
    };
    RedditSession.client = () => MockClient((r) async {
          seen.add(r);
          if (status != 200) return http.Response('no', status);
          if (r.url.path == '/api/me.json') return http.Response(jsonEncode({'name': 'amy'}), 200);
          if (r.url.path == '/subreddits/mine/subscriber.json') {
            final second = r.url.queryParameters['after'] == 't5_2';
            return http.Response(
                jsonEncode({
                  'data': {
                    'after': second ? null : 't5_2',
                    'children': second
                        ? [
                            {'data': {'display_name': 'cats', 'subreddit_type': 'public'}}
                          ]
                        : [
                            {'data': {'display_name': 'pics', 'subreddit_type': 'public'}},
                            {'data': {'display_name': 'u_someone', 'subreddit_type': 'user'}},
                          ],
                  }
                }),
                200);
          }
          return http.Response(jsonEncode({'data': {'children': []}}), 200);
        });
  });

  tearDown(RedditSession.logout);

  test('only the reddit_session cookie is picked from the page cookies', () {
    expect(RedditSession.pick('loid=1; reddit_session=abc.def; token_v2=x'), 'abc.def');
    expect(RedditSession.pick('loid=1; token_v2=x'), isNull);
    expect(RedditSession.pick(null), isNull);
    expect(RedditSession.pick('reddit_session='), isNull);
  });

  test('saving stores only the cookie and the account name; logging out deletes both', () async {
    await RedditSession.save('abc');
    expect(store['redditSessionCookie'], 'abc');
    expect(RedditSession.username.value, 'amy');
    expect(store.keys.toSet(), {'redditSessionCookie', 'redditSessionUser'});
    await RedditSession.logout();
    expect(store, isEmpty);
    expect(RedditSession.active, isFalse);
  });

  test('requests carry the cookie and the honest Hobees User-Agent', () async {
    await RedditSession.save('abc');
    seen.clear();
    await RedditSession.getJson('/user/amy/saved', {'limit': '100'});
    final r = seen.single;
    expect(r.url.toString(), startsWith('https://www.reddit.com/user/amy/saved.json'));
    expect(r.url.queryParameters['raw_json'], '1');
    expect(r.headers['Cookie'], 'reddit_session=abc');
    expect(r.headers['User-Agent'], 'android:io.github.cscott0108.hobees:v1.0 (by /u/amy)');
    expect(r.headers['User-Agent'], isNot(contains('Mozilla')), reason: 'never pretends to be a browser');
  });

  test('401 or 403 ends the session (the app falls back to no login)', () async {
    await RedditSession.save('abc');
    status = 403;
    await expectLater(RedditSession.getJson('/new'), throwsA(isA<SessionEndedException>()));
    expect(RedditSession.ended.value, isTrue);
    expect(RedditSession.active, isFalse);
  });

  test('subscriptions: every page, subreddits only, A to Z', () async {
    await RedditSession.save('abc');
    expect(await RedditSession.subscriptions(), ['cats', 'pics']);
  });
}
