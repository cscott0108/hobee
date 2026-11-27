import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hobee/download.dart';
import 'package:hobee/models.dart';

void main() {
  late Directory tmp;
  late Map<String, http.Response> web;
  late List<String> asked;

  setUp(() async {
    originalQuality.value = true;
    tmp = await Directory.systemTemp.createTemp('hobees_dl');
    Downloader.tempDir = () async => tmp;
    web = {};
    asked = [];
    Downloader.client = () => MockClient((r) async {
          asked.add(r.url.toString());
          expect(r.followRedirects, isFalse, reason: 'redirects are followed by hand');
          return web[r.url.toString()] ?? http.Response('', 404);
        });
  });
  tearDown(() => tmp.delete(recursive: true));

  http.Response bytes(String s) => http.Response(s, 200, headers: {'content-type': 'image/png'});
  http.Response moved(String to) => http.Response('', 302, headers: {'location': to});

  test("imgur's removed placeholder is never saved", () async {
    web['https://i.imgur.com/abc.jpg'] = moved('https://i.imgur.com/removed.png');
    web['https://i.imgur.com/removed.png'] = bytes('PLACEHOLDER');
    await expectLater(Downloader.prepare(MediaItem(MediaType.image, 'https://i.imgur.com/abc.jpg', 't')), throwsA(isA<MediaRemoved>()));
    expect(asked, isNot(contains('https://i.imgur.com/removed.png')));
  });

  test('removed at the host but the Reddit preview still has it: the preview is saved', () async {
    web['https://i.imgur.com/abc.jpg'] = moved('https://i.imgur.com/removed.png');
    web['https://preview.redd.it/abc.jpg'] = bytes('PREVIEW');
    final (f, _, _, _) = await Downloader.prepare(
        MediaItem(MediaType.image, 'https://i.imgur.com/abc.jpg', 't', preview: 'https://preview.redd.it/abc.jpg'));
    expect(await f.readAsString(), 'PREVIEW');
  });

  test('gone everywhere (404s) says removed, so the thumbnail can be offered', () async {
    await expectLater(
        Downloader.prepare(MediaItem(MediaType.image, 'https://i.redd.it/x.jpg', 't', preview: 'https://preview.redd.it/x.jpg')),
        throwsA(isA<MediaRemoved>()));
  });

  test('a real picture still downloads, ordinary redirects included', () async {
    web['https://i.redd.it/a.jpg'] = bytes('REAL');
    final (f, _, _, _) = await Downloader.prepare(MediaItem(MediaType.image, 'https://i.redd.it/a.jpg', 't'));
    expect(await f.readAsString(), 'REAL');
    web['https://imgur.com/b.jpg'] = moved('https://i.imgur.com/b.jpg');
    web['https://i.imgur.com/b.jpg'] = bytes('REAL2');
    final (g, _, _, _) = await Downloader.prepare(MediaItem(MediaType.image, 'https://imgur.com/b.jpg', 't'));
    expect(await g.readAsString(), 'REAL2');
  });

  test('a refused request (403) is an error, not "removed"', () async {
    web['https://i.redd.it/a.jpg'] = http.Response('', 403);
    await expectLater(Downloader.prepare(MediaItem(MediaType.image, 'https://i.redd.it/a.jpg', 't')),
        throwsA(isNot(isA<MediaRemoved>())));
  });
}
