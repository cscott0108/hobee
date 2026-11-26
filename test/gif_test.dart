import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/clean_image.dart';
import 'package:hobee/models.dart';
import 'package:hobee/viewer.dart';

void main() {
  Map<String, dynamic> gifPost({bool mp4 = true}) => {
        'url': 'https://i.redd.it/abc123.gif',
        'post_hint': 'image',
        'preview': {
          'images': [
            {
              'source': {'url': 'https://preview.redd.it/abc123.gif?width=640&amp;s=1', 'width': 640, 'height': 480},
              'resolutions': [
                {'url': 'https://preview.redd.it/abc123.gif?width=320&amp;crop=smart&amp;s=2', 'width': 320, 'height': 240},
              ],
              'variants': {
                'gif': {'source': {'url': 'https://preview.redd.it/abc123.gif?format=gif&amp;s=3'}},
                if (mp4) 'mp4': {'source': {'url': 'https://preview.redd.it/abc123.gif?format=mp4&amp;s=4'}},
              },
            }
          ],
        },
      };

  test('a GIF post with an MP4 copy opens as a video (play/pause, progress)', () {
    final m = parseMedia(gifPost()).single;
    expect(m.type, MediaType.video);
    expect(m.url, 'https://preview.redd.it/abc123.gif?format=mp4&s=4');
    expect(m.thumb, startsWith('https://preview.redd.it/abc123.gif?width=320'));
  });

  test('a GIF post without one stays an animated picture', () {
    final m = parseMedia(gifPost(mp4: false)).single;
    expect(m.type, MediaType.gif);
    expect(m.url, 'https://i.redd.it/abc123.gif');
  });

  test('GIFs skip the JPEG cleanup, which keeps one frame only', () {
    expect(cleanJpegs.value, isTrue);
    expect(looksAnimated('https://i.redd.it/abc123.gif'), isTrue);
    expect(looksAnimated('https://preview.redd.it/abc123.gif?format=png8&s=1'), isTrue);
    expect(looksAnimated('https://external-preview.redd.it/x.png?format=gif&s=1'), isTrue);
    expect(looksAnimated('https://i.redd.it/abc123.jpg'), isFalse);
    expect(viewerProvider('https://i.redd.it/abc123.gif', 2048), isA<ResizeImage>());
    expect(viewerProvider('https://i.redd.it/abc123', 2048, animated: true), isA<ResizeImage>());
    expect(viewerProvider('https://i.redd.it/abc123.jpg', 2048), isA<CleanNetworkImage>());
  });
}
