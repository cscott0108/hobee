import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/age.dart';

void main() {
  final now = DateTime(2026, 11, 25, 12);
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch ~/ 1000;

  test('short age for tiles', () {
    expect(shortAge(ago(const Duration(seconds: 20)), now: now), 'now');
    expect(shortAge(ago(const Duration(minutes: 5)), now: now), '5m');
    expect(shortAge(ago(const Duration(hours: 3)), now: now), '3h');
    expect(shortAge(ago(const Duration(days: 2)), now: now), '2d');
    expect(shortAge(ago(const Duration(days: 150)), now: now), '5mo');
    expect(shortAge(ago(const Duration(days: 800)), now: now), '2y');
    expect(shortAge(0, now: now), '');
  });

  test('date, time and age for the viewer', () {
    final c = DateTime(2026, 11, 22, 14, 5).millisecondsSinceEpoch ~/ 1000;
    expect(postedWhen(c, now: DateTime(2026, 11, 25, 15)), '22 Nov 2026, 14:05 · 3d ago');
    expect(postedWhen(ago(const Duration(seconds: 5)), now: now), endsWith('· just now'));
  });
}
