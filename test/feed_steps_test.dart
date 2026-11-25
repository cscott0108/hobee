import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/gallery.dart';
import 'package:hobee/models.dart';

Post post(int i) => Post.fromJson({
      'id': 'p$i', 'title': 't', 'subreddit': 's', 'author': 'a', 'permalink': '/p', 'created_utc': 1700000000 - i,
      'url': 'https://i.redd.it/$i.jpg', 'post_hint': 'image',
    })!;

void main() {
  test('a feed shows its first 500 posts, then the next 500, in the same order', () {
    final all = [for (var i = 0; i < 1234; i++) post(i)];
    var (shown, more) = capResults(all, resultStep);
    expect(shown.length, 500);
    expect(shown.first.id, 'p0');
    expect(more, true);
    (shown, more) = capResults(all, 2 * resultStep);
    expect(shown.length, 1000);
    expect(shown[500].id, 'p500');
    expect(more, true);
    (shown, more) = capResults(all, 3 * resultStep);
    expect(shown.length, 1234);
    expect(more, false);
    final few = all.sublist(0, 10);
    expect(capResults(few, resultStep), (few, false));
  });
}
