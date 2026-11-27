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
    VideoPoster.probe = (_) async => null; // no network in tests
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

  test('a copy over the download cap is read straight from its link when it works', () async {
    VideoPoster.fetch = (_) async => null; // too big (or not found)
    VideoPoster.frame = (_) async => null;
    VideoPoster.probe = (u) async => u.contains('CMAF_220') ? 206 : 403;
    final read = <String>[];
    VideoPoster.frameFromUrl = (u) async {
      read.add(u);
      return Uint8List.fromList([0xff, 0xd8, 5]);
    };
    final f = await VideoPoster.of(MediaItem(MediaType.video, 'https://v.redd.it/big/DASH_720.mp4', ''));
    expect(f?.readAsBytesSync(), [0xff, 0xd8, 5]);
    expect(read, ['https://v.redd.it/big/CMAF_220.mp4'], reason: 'links that refuse are not read');
  });

  test('no frame when no copy can be read', () async {
    VideoPoster.fetch = (_) async => null;
    VideoPoster.frame = (_) async => null;
    expect(await VideoPoster.of(MediaItem(MediaType.video, 'https://i.imgur.com/x.mp4', '')), isNull);
  });

  test('a video that plays in the viewer gives its tile a frame when the other ways failed', () async {
    VideoPoster.fetch = (_) async => null;
    VideoPoster.frame = (_) async => null;
    final read = <String>[];
    VideoPoster.frameFromUrl = (u) async {
      read.add(u);
      return Uint8List.fromList([0xff, 0xd8, 7]);
    };
    final m = MediaItem(MediaType.video, 'https://v.redd.it/q/DASH_720.mp4', '');
    final other = MediaItem(MediaType.video, 'https://v.redd.it/w/DASH_720.mp4', 'https://preview.redd.it/w.jpg');
    await VideoPoster.fromPlaying(other, 'https://v.redd.it/w/DASH_720.mp4');
    expect(read, isEmpty, reason: 'its tile has a picture, so nothing is read');

    VideoPoster.need(m); // the tile showed the film icon
    expect(await VideoPoster.of(m), isNull);
    var bumps = 0;
    VideoPoster.saved.addListener(() => bumps++);
    await VideoPoster.fromPlaying(m, 'https://v.redd.it/q/HLSPlaylist.m3u8', hls: true);
    expect(read, ['https://v.redd.it/q/CMAF_220.mp4'], reason: 'a stream playlist is read from the plain files instead, CMAF first');
    expect(bumps, 1);
    expect((await VideoPoster.of(m))?.readAsBytesSync(), [0xff, 0xd8, 7]);
    await VideoPoster.fromPlaying(m, 'https://v.redd.it/q/HLSPlaylist.m3u8', hls: true);
    expect(read.length, 1, reason: 'once per video');
  });

  test('a video with no frame is checked once: dead only when every link refuses or is deleted', () async {
    final codes = {'https://v.redd.it/d/DASH_720.mp4': 403, 'https://v.redd.it/d/HLSPlaylist.m3u8': 404};
    var asked = 0;
    VideoPoster.probe = (u) async {
      asked++;
      return codes[u];
    };
    final m = MediaItem(MediaType.video, 'https://v.redd.it/d/DASH_720.mp4', '', hls: 'https://v.redd.it/d/HLSPlaylist.m3u8');
    expect(await VideoPoster.deadCode(m), 410);
    expect(await VideoPoster.deadCode(m), 410);
    expect(asked, 2, reason: 'once per video');
    codes['https://v.redd.it/e/DASH_720.mp4'] = 206;
    final ok = MediaItem(MediaType.video, 'https://v.redd.it/e/DASH_720.mp4', '', hls: 'https://v.redd.it/e/HLSPlaylist.m3u8');
    expect(await VideoPoster.deadCode(ok), isNull, reason: 'a link that works (or gives no answer) means not dead');
  });

  test("a video tile doesn't try its backup video file as a picture", () {
    final v = MediaItem(MediaType.video, 'https://media.redgifs.com/x', 'https://external-preview.redd.it/x.jpg',
        preview: 'https://v.redd.it/zz/DASH_480.mp4');
    expect(tileUrls(v), ['https://external-preview.redd.it/x.jpg']);
  });
}
