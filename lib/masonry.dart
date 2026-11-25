import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// Settings → Grid: true = tiles keep the media's shape (masonry), false = square tiles.
final originalShapeGrid = ValueNotifier<bool>(true);

/// Tile shapes are clamped to this range so one very tall or very wide image can't dominate the grid.
const double minTileAspect = 0.4, maxTileAspect = 2.5;

/// Aspect ratio (width / height) a tile is drawn with. Unknown sizes, and the Square grid setting, give 1.
double tileAspect(double? aspect, {bool square = false}) =>
    square || aspect == null || !aspect.isFinite || aspect <= 0 ? 1.0 : aspect.clamp(minTileAspect, maxTileAspect).toDouble();

/// Shortest-column masonry layout of one section. Ties go to the leftmost column,
/// so equal (square) tiles fill row by row, exactly like a fixed grid.
class Masonry {
  /// Item indices per column, top to bottom.
  final List<List<int>> columns;

  /// Top of each item within the section.
  final List<double> top;

  /// Height of the tallest column.
  final double extent;

  Masonry._(this.columns, this.top, this.extent);

  factory Masonry(List<double> aspects, int cols, double width) {
    final colW = width / cols;
    final heights = List<double>.filled(cols, 0);
    final columns = [for (var c = 0; c < cols; c++) <int>[]];
    final top = List<double>.filled(aspects.length, 0);
    for (var i = 0; i < aspects.length; i++) {
      var c = 0;
      for (var k = 1; k < cols; k++) {
        if (heights[k] < heights[c] - 1e-6) c = k;
      }
      top[i] = heights[c];
      heights[c] += colW / aspects[i];
      columns[c].add(i);
    }
    return Masonry._(columns, top, heights.fold(0.0, math.max));
  }
}

/// Multi-picture posts are drawn as one framed block across the grid: a header line (user, subreddit, count)
/// and the post's pictures in their own masonry inside the frame. These sizes are shared by the widget and the
/// scroll maths, so jumping and keeping your place stay exact.
const double groupHeaderH = 30, groupPad = 4, groupGap = 6;

/// Height of a framed block whose pictures take [inner].
double groupBlockExtent(double inner) => 2 * groupGap + groupHeaderH + inner + groupPad;

/// A run of a section's items, [start, end): plain mosaic tiles, or all pictures of one post (a framed block).
class Piece {
  final int start, end;
  final bool group;
  const Piece(this.start, this.end, this.group);
}

/// Splits a section into pieces. [groups][i] is the post id when item i belongs to a multi-picture post,
/// else null; two or more neighbouring items of the same post make a block.
List<Piece> sectionPieces(List<String?> groups) {
  bool startsGroup(int j) => groups[j] != null && j + 1 < groups.length && groups[j + 1] == groups[j];
  final out = <Piece>[];
  var i = 0;
  while (i < groups.length) {
    if (startsGroup(i)) {
      var j = i + 1;
      while (j < groups.length && groups[j] == groups[i]) {
        j++;
      }
      out.add(Piece(i, j, true));
      i = j;
    } else {
      var j = i + 1;
      while (j < groups.length && !startsGroup(j)) {
        j++;
      }
      out.add(Piece(i, j, false));
      i = j;
    }
  }
  return out;
}

/// Top of each item within a section and the section's height (without its header), blocks included.
({List<double> top, double extent}) layoutSection(List<double> aspects, List<String?>? groups, int cols, double width) {
  if (groups == null || groups.every((g) => g == null)) {
    final m = Masonry(aspects, cols, width);
    return (top: m.top, extent: m.extent);
  }
  final top = List<double>.filled(aspects.length, 0);
  var y = 0.0;
  for (final p in sectionPieces(groups)) {
    final inner = p.group ? width - 2 * groupPad : width;
    final m = Masonry(aspects.sublist(p.start, p.end), cols, inner);
    final base = p.group ? y + groupGap + groupHeaderH : y;
    for (var k = 0; k < m.top.length; k++) {
      top[p.start + k] = base + m.top[k];
    }
    y += p.group ? groupBlockExtent(m.extent) : m.extent;
  }
  return (top: top, extent: y);
}

/// Top of every item, measured from the top of the first section, for a list of sections that each
/// start with a header of [headerH]. Keys are taken from [keys] (same shape as [aspects]).
Map<String, double> sectionTops(List<List<String>> keys, List<List<double>> aspects, int cols, double width, double headerH,
    {List<List<String?>>? groups}) {
  final out = <String, double>{};
  var y = 0.0;
  for (var s = 0; s < keys.length; s++) {
    final m = layoutSection(aspects[s], groups?[s], cols, width);
    y += headerH;
    for (var i = 0; i < keys[s].length; i++) {
      out.putIfAbsent(keys[s][i], () => y + m.top[i]);
    }
    y += m.extent;
  }
  return out;
}

/// Offset of section [s] from the top of the first section.
double sectionOffset(List<List<double>> aspects, int s, int cols, double width, double headerH, {List<List<String?>>? groups}) {
  var off = 0.0;
  for (var i = 0; i < s && i < aspects.length; i++) {
    off += headerH + layoutSection(aspects[i], groups?[i], cols, width).extent;
  }
  return off;
}

/// One framed block: [header] on top, then the pictures in a masonry of [cols] inside the frame, as slivers:
/// like the plain mosaic, a picture is only built (and so loaded) when it scrolls near the screen.
/// Its height is exactly [groupBlockExtent] of the inner masonry (the frame is drawn over, not around, so it
/// takes no space).
Widget groupSliver({required List<double> aspects, required int cols, required Widget header, required Widget Function(int k) tile, required Color color}) {
  final radius = BorderRadius.circular(10);
  return SliverPadding(
    padding: const EdgeInsets.symmetric(vertical: groupGap),
    sliver: DecoratedSliver(
      key: const Key('group-block'),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: radius),
      sliver: DecoratedSliver(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(border: Border.all(color: color, width: 2), borderRadius: radius),
        sliver: SliverPadding(
          padding: const EdgeInsets.fromLTRB(groupPad, 0, groupPad, groupPad),
          sliver: SliverMainAxisGroup(slivers: [
            SliverToBoxAdapter(child: SizedBox(height: groupHeaderH, child: header)),
            masonrySliver(aspects, cols, tile),
          ]),
        ),
      ),
    ),
  );
}

/// Where the view is: the tile at or just above [offset] and how far below its top the view starts.
/// Saved when you leave a feed, so coming back puts you on the same tile even if newer posts came in above.
({String key, double delta})? scrollPlace(Map<String, double> tops, double offset) {
  if (offset <= 0) return null;
  String? best;
  var bestTop = double.negativeInfinity;
  tops.forEach((k, y) {
    if (y <= offset && y > bestTop) {
      best = k;
      bestTop = y;
    }
  });
  final b = best;
  return b == null ? null : (key: b, delta: offset - bestTop);
}

/// Keep the view on the same item when items above it disappear or move: take the first item at or below
/// the current offset that is still shown (or the last one above it) and shift by how far it moved.
double anchoredOffset(double offset, Map<String, double> oldTops, Map<String, double> newTops) {
  String? below, above;
  double bestBelow = double.infinity, bestAbove = -double.infinity;
  oldTops.forEach((k, y) {
    if (!newTops.containsKey(k)) return;
    if (y >= offset && y < bestBelow) {
      bestBelow = y;
      below = k;
    } else if (y < offset && y > bestAbove) {
      bestAbove = y;
      above = k;
    }
  });
  final k = below ?? above;
  if (k == null) return offset;
  final o = offset + newTops[k]! - oldTops[k]!;
  return o < 0 ? 0 : o;
}

/// Lazy masonry sliver: [cols] side-by-side lists, each tile sized from its aspect ratio before anything loads.
/// [tile] gets the index into [aspects].
Widget masonrySliver(List<double> aspects, int cols, Widget Function(int index) tile) {
  final m = Masonry(aspects, cols, 1); // column assignment doesn't depend on width; heights scale with it
  return SliverLayoutBuilder(builder: (_, c) {
    // Still below the area the list builds ahead: an empty box of the same height. (A list builds the first
    // item of each column even there, which for a long feed of blocks meant hundreds of pictures loading.)
    if (c.remainingCacheExtent <= 0) return SliverToBoxAdapter(child: SizedBox(height: m.extent * c.crossAxisExtent));
    return SliverCrossAxisGroup(slivers: [
      for (final col in m.columns)
        SliverVariedExtentList(
          itemExtentBuilder: (j, dims) => j < col.length ? dims.crossAxisExtent / aspects[col[j]] : 0.0,
          delegate: SliverChildBuilderDelegate((_, j) => tile(col[j]), childCount: col.length),
        ),
    ]);
  });
}
