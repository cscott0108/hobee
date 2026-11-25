import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/masonry.dart';

void main() {
  test('a multi-picture post becomes one block; single posts stay mosaic tiles', () {
    final p = sectionPieces(['a', null, 'g', 'g', 'g', null, 'h']);
    expect([for (final x in p) (x.start, x.end, x.group)], [(0, 2, false), (2, 5, true), (5, 7, false)],
        reason: 'a lone item of a post (the rest filtered out) is just a tile');
  });

  test('no multi-picture posts: the plain mosaic, unchanged', () {
    final a = [1.0, 0.5, 2.0, 1.0];
    final l = layoutSection(a, [null, null, null, null], 3, 300);
    final m = Masonry(a, 3, 300);
    expect(l.top, m.top);
    expect(l.extent, m.extent);
  });

  test('items inside a block sit under its header, and the next tiles start after the block', () {
    // 3 square tiles, then a 3-picture post, then 1 tile; width 300 -> 100 px columns.
    final l = layoutSection([1, 1, 1, 1, 1, 1, 1], [null, null, null, 'g', 'g', 'g', null], 3, 300);
    expect(l.top.sublist(0, 3), [0, 0, 0]);
    final innerCol = (300 - 2 * groupPad) / 3;
    expect(l.top[3], 100 + groupGap + groupHeaderH);
    final blockEnd = 100 + groupBlockExtent(innerCol);
    expect(l.top[6], closeTo(blockEnd, 1e-9));
    expect(l.extent, closeTo(blockEnd + 100, 1e-9));
  });

  Widget scroll(List<Widget> slivers) => MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 360, height: 600, child: CustomScrollView(slivers: slivers)),
        ),
      );

  testWidgets('the block is exactly as tall as the scroll maths says', (t) async {
    const aspects = [1.0, 0.75, 1.5, 1.0];
    await t.pumpWidget(scroll([
      groupSliver(
        aspects: aspects,
        cols: 3,
        color: Colors.red,
        header: const Text('u/amy · r/pics'),
        tile: (k) => ColoredBox(key: Key('t$k'), color: Colors.blue),
      ),
      const SliverToBoxAdapter(child: SizedBox(key: Key('after'), height: 10)),
    ]));
    final inner = Masonry(aspects, 3, 360 - 2 * groupPad).extent;
    expect(t.getTopLeft(find.byKey(const Key('after'))).dy, closeTo(groupBlockExtent(inner), 0.01),
        reason: 'gaps, header, pictures and bottom padding');
    expect(t.getSize(find.byKey(const Key('t0'))).width, closeTo((360 - 2 * groupPad) / 3, 0.01));
    expect(find.text('u/amy · r/pics'), findsOneWidget);
  });

  testWidgets('a block far below the screen builds none of its pictures', (t) async {
    final built = <int>{};
    await t.pumpWidget(scroll([
      const SliverToBoxAdapter(child: SizedBox(height: 20000)),
      groupSliver(
        aspects: List.filled(30, 1.0),
        cols: 3,
        color: Colors.red,
        header: const Text('far'),
        tile: (k) {
          built.add(k);
          return const ColoredBox(color: Colors.blue);
        },
      ),
    ]));
    expect(built, isEmpty);
    await t.drag(find.byType(CustomScrollView), const Offset(0, -19800));
    await t.pump();
    expect(built, isNotEmpty, reason: 'built once it scrolls near');
    expect(built.length, lessThan(30), reason: 'only the rows near the screen');
  });

  testWidgets('a plain mosaic below the screen builds nothing and keeps its height', (t) async {
    final built = <int>{};
    final aspects = [1.0, 0.5, 2.0, 1.0, 1.0, 0.75];
    await t.pumpWidget(scroll([
      const SliverToBoxAdapter(child: SizedBox(height: 20000)),
      masonrySliver(aspects, 3, (k) {
        built.add(k);
        return const ColoredBox(color: Colors.blue);
      }),
      const SliverToBoxAdapter(child: SizedBox(key: Key('after'), height: 10)),
    ]));
    expect(built, isEmpty);
    await t.drag(find.byType(CustomScrollView), const Offset(0, -19700));
    await t.pump();
    expect(built.length, aspects.length);
    expect(t.getTopLeft(find.byKey(const Key('after'))).dy, closeTo(20000 - 19700 + Masonry(aspects, 3, 360).extent, 0.01));
  });
}
