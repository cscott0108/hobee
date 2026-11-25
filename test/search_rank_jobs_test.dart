import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/filters.dart';
import 'package:hobee/find.dart';
import 'package:hobee/models.dart';
import 'package:hobee/relevance.dart';

Post post(int i) => Post.fromJson({
      'id': 'p$i', 'title': i.isEven ? 'cute kitten $i' : 'dog $i', 'subreddit': 's', 'author': 'a', 'permalink': '/p',
      'created_utc': 1700000000 + i, 'url': 'https://i.redd.it/img$i.jpeg', 'post_hint': 'image',
    })!;

List<Post> feed(int n) => [for (var i = 0; i < n; i++) post(i)];

void main() {
  final jobs = <Completer<Map<int, RHit>>>[];
  setUp(() {
    Rel.debugReset();
    jobs.clear();
    Rel.runJob = (_) {
      final c = Completer<Map<int, RHit>>();
      jobs.add(c);
      return c.future;
    };
    searchQuery.value = 'kitten';
  });
  tearDown(() {
    searchQuery.value = '';
    Rel.debugReset();
  });

  Map<int, RHit> evens(int n) => {for (var i = 0; i < n; i += 2) i: const RHit(1, 1)};

  test('reloading the same posts (a new list) starts no new ranking', () async {
    final n = Rel.inlineMax + 500;
    Rel.hitsFor(feed(n));
    expect(Rel.jobsStarted, 1);
    jobs.single.complete(evens(n));
    await pumpEventQueue();
    expect(Rel.hitsFor(feed(n))?.length, n ~/ 2);
    expect(Rel.hitsFor(feed(n))?.length, n ~/ 2);
    expect(Rel.jobsStarted, 1);
  });

  test('reloads during a ranking queue only the newest list; old results stay shown', () async {
    final n = Rel.inlineMax + 500;
    expect(Rel.hitsFor(feed(n)), isNull); // nothing ranked yet: plain matching
    jobs.single.complete(evens(n));
    await pumpEventQueue();
    // The refresher saves posts three times while the next ranking runs.
    Rel.hitsFor(feed(n + 10));
    expect(Rel.jobsStarted, 2);
    expect(Rel.hitsFor(feed(n + 20))?.length, n ~/ 2, reason: 'keeps the last ranking meanwhile');
    Rel.hitsFor(feed(n + 30));
    expect(Rel.jobsStarted, 2, reason: 'one job at a time');
    jobs[1].complete(evens(n + 10));
    await pumpEventQueue();
    expect(Rel.jobsStarted, 3, reason: 'then only the newest list');
    jobs[2].complete(evens(n + 30));
    await pumpEventQueue();
    expect(Rel.hitsFor(feed(n + 30))?.length, (n + 30) ~/ 2);
    expect(Rel.jobsStarted, 3);
  });

  test('a finished ranking for an old query is dropped', () async {
    final n = Rel.inlineMax + 500;
    Rel.hitsFor(feed(n));
    searchQuery.value = 'puppy';
    jobs.single.complete(evens(n));
    await pumpEventQueue();
    expect(Rel.hitsFor(feed(n)), isNull);
    expect(Rel.jobsStarted, 2);
  });

  test('typo matching can be turned off', () {
    final p = post(2);
    expect(textMatches(p, queryTerms('kiten')), true);
    expect(textMatches(p, queryTerms('kiten'), typos: false), false);
    expect(textMatches(p, queryTerms('kitten'), typos: false), true);
  });

  test('a big feed matches without typos while its ranking runs; a small one keeps them', () {
    searchQuery.value = 'kiten';
    expect(filterAndCount(feed(Rel.inlineMax + 500)), isEmpty);
    Rel.debugReset();
    expect(filterAndCount(feed(100)).length, 50);
  });
}
