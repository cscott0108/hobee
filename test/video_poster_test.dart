import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/models.dart';
import 'package:hobee/tile_image.dart';
import 'package:hobee/video_poster.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('poster');
    VideoPoster.debugReset();
    VideoPoster.dir = () async => tmp;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a video with no picture gets a frame from its smallest copy, saved once', () async {
    final asked = <String>[];
    VideoPoster.fetch = (u) async {
      asked.add(u);
      return u.contains('CMAF') ? null : Uint8List.fromList([1, 2, 3]);
    };
    var frames = 0;
    VideoPoster.frame = (p) async {
      frames++;
      expect(File(p).existsSync(), isTrue, reason: 'the frame is read from the downloaded copy');
      return Uint8List.fromList([0xff, 0xd8, 9]);
    };
    final m = MediaItem(MediaType.video, 'https://v.redd.it/abc/DASH_720.mp4', '');
    final f = await VideoPoster.of(m);
    expect(f, isNotNull);
    expect(f!.readAsBytesSync(), [0xff, 0xd8, 9]);
    expect(asked, ['https://v.redd.it/abc/CMAF_220.mp4', 'https://v.redd.it/abc/DASH_220.mp4']);
    expect(tmp.listSync(recursive: true).whereType<File>().where((x) => x.path.endsWith('.mp4')), isEmpty,
        reason: 'the downloaded copy is deleted');

    VideoPoster.debugReset(); // a new session: the saved frame on disk is used, nothing is downloaded
    expect(await VideoPoster.of(m), isNotNull);
    expect(frames, 1);
    expect(asked.length, 2);
  });

  test('no frame when no copy can be read', () async {
    VideoPoster.fetch = (_) async => null;
    VideoPoster.frame = (_) async => null;
    expect(await VideoPoster.of(MediaItem(MediaType.video, 'https://i.imgur.com/x.mp4', '')), isNull);
  });

  test("a video tile doesn't try its backup video file as a picture", () {
    final v = MediaItem(MediaType.video, 'https://media.redgifs.com/x', 'https://external-preview.redd.it/x.jpg',
        preview: 'https://v.redd.it/zz/DASH_480.mp4');
    expect(tileUrls(v), ['https://external-preview.redd.it/x.jpg']);
  });
}
