import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/following.dart';
import 'package:hobee/follows.dart';

void main() {
  test("background requests wait for the open page's requests to the same host", () async {
    Archive.pacing = true;
    Archive.giveWay = const Duration(milliseconds: 200);
    final order = <String>[];
    try {
      final fg1 = Archive.paceForTest('prio.test').then((_) => order.add('page 1'));
      final bg = Archive.background(() => Archive.paceForTest('prio.test')).then((_) => order.add('refresher'));
      final fg2 = Archive.paceForTest('prio.test').then((_) => order.add('page 2'));
      final other = Archive.background(() => Archive.paceForTest('other.test')).then((_) => order.add('other host'));
      await Future.wait([fg1, bg, fg2, other]);
      expect(order.indexOf('page 1'), lessThan(order.indexOf('refresher')));
      expect(order.indexOf('page 2'), lessThan(order.indexOf('refresher')));
      expect(order.indexOf('other host'), lessThan(order.indexOf('page 2')), reason: 'another host is not held up');
    } finally {
      Archive.pacing = false;
      Archive.giveWay = const Duration(seconds: 2);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('the opened channel moves to the front of a running refresh round', () async {
    const a = Follow(FollowKind.user, 'Amy'), b = Follow(FollowKind.sub, 'pics'), c = Follow(FollowKind.user, 'bob');
    final q = Following.debugRound('fol:1', [a, b, c]);
    Following.bump(sub: 'PICS');
    expect(q, [b, a, c]);
    Following.bump(author: 'bob');
    expect(q, [c, b, a]);
    Following.bump(author: 'nobody');
    expect(q, [c, b, a]);
    Following.debugReset();
  });
}
