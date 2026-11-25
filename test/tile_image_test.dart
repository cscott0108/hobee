import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/models.dart';
import 'package:hobee/tile_image.dart';

void main() {
  test('a tile tries the preview, the resized copy, then the original picture', () {
    final m = MediaItem(MediaType.image, 'https://i.redd.it/a.jpg', 'https://b.thumbs.redditmedia.com/a.jpg', preview: 'https://preview.redd.it/a.jpg');
    expect(tileUrls(m), ['https://b.thumbs.redditmedia.com/a.jpg', 'https://preview.redd.it/a.jpg', 'https://i.redd.it/a.jpg']);
    final v = MediaItem(MediaType.video, 'https://v.redd.it/x/DASH.mp4', 'https://preview.redd.it/x.jpg');
    expect(tileUrls(v), ['https://preview.redd.it/x.jpg'], reason: 'a video tile never decodes the video');
  });

  Future<(List<String>, int)> run(WidgetTester t, Map<String, int?> status) async {
    final tried = <String>[];
    var gone = 0;
    TileImage.image = (u, w, l, onError) => Builder(builder: (c) {
          tried.add(u);
          final code = status[u];
          if (code == null) return const ColoredBox(key: Key('shown'), color: Colors.green);
          return onError(c, NetworkImageLoadException(statusCode: code, uri: Uri.parse(u)), null);
        });
    await t.pumpWidget(MaterialApp(home: SizedBox(width: 100, height: 100, child: TileImage(urls: status.keys.toList(), onGone: () => gone++))));
    for (var i = 0; i < 5; i++) {
      await t.pump();
    }
    return (tried.toSet().toList(), gone);
  }

  testWidgets('a dead preview falls back to the next address, and the post is not marked gone', (t) async {
    final (tried, gone) = await run(t, {'a': 404, 'b': null, 'c': null});
    expect(tried, ['a', 'b']);
    expect(find.byKey(const Key('shown')), findsOneWidget);
    expect(gone, 0);
  });

  testWidgets('only when every address is deleted is the post gone', (t) async {
    final (_, gone) = await run(t, {'a': 404, 'b': 410});
    expect(gone, 1);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });

  testWidgets('a failure that is not a deletion (blocked, offline) never marks it gone', (t) async {
    final (_, gone) = await run(t, {'a': 404, 'b': 403});
    expect(gone, 0);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });
}
