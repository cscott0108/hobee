import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/reddit_login.dart';
import 'package:hobee/reddit_session.dart';

void main() {
  final store = <String, String>{};

  setUp(() {
    store.clear();
    RedditSession.read = (k) async => store[k];
    RedditSession.write = (k, v) async {
      if (v == null) {
        store.remove(k);
      } else {
        store[k] = v;
      }
    };
    RedditSession.cookie.value = null;
    RedditSession.ended.value = false;
  });

  testWidgets('the warning comes before the first login, and Cancel stops there', (t) async {
    await t.pumpWidget(MaterialApp(home: Builder(builder: (c) => TextButton(onPressed: () => startSessionLogin(c), child: const Text('go')))));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.textContaining('Hobees never sees your password'), findsOneWidget);
    expect(find.textContaining('could flag the account'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.byType(RedditLoginScreen), findsNothing);
    expect(store['redditSessionWarned'], isNull, reason: 'asked again next time');
  });

  testWidgets('settings: not logged in offers the login; an ended session says so', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: RedditSessionSettings())));
    expect(find.text('Reddit session: not logged in'), findsOneWidget);
    expect(find.byKey(const Key('session-login')), findsOneWidget);
    RedditSession.cookie.value = 'abc';
    RedditSession.username.value = 'amy';
    await t.pump();
    expect(find.text('Reddit session: u/amy'), findsOneWidget);
    expect(find.byKey(const Key('session-import')), findsOneWidget);
    RedditSession.ended.value = true;
    await t.pump();
    expect(find.text('Reddit session ended'), findsOneWidget);
    expect(find.text('Log in again'), findsOneWidget);
  });
}
