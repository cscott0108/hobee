import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/masonry.dart';

void main() {
  const tops = {'a#0': 0.0, 'b#0': 0.0, 'c#0': 120.0, 'd#0': 250.0, 'e#0': 400.0};

  test('remembers the tile at the top of the view and how far into it', () {
    final p = scrollPlace(tops, 300)!;
    expect(p.key, 'd#0');
    expect(p.delta, 50);
  });

  test('at the very top there is nothing to remember', () {
    expect(scrollPlace(tops, 0), isNull);
  });

  test('coming back after newer posts arrived above lands on the same tile', () {
    final p = scrollPlace(tops, 300)!;
    final moved = {for (final e in tops.entries) e.key: e.value + 500, 'new#0': 0.0};
    expect(moved[p.key]! + p.delta, 800, reason: 'same tile, same spot within it');
  });
}
