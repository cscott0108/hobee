import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/dedupe.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() => Dedupe.client = http.Client.new);

  /// A server sending [chunks] chunks of 64 KB; returns how many were sent so far.
  int Function() serve(int chunks, {int? length, int status = 200}) {
    var sent = 0;
    Dedupe.client = () => MockClient.streaming((rq, _) async {
          Stream<List<int>> body() async* {
            for (var i = 0; i < chunks; i++) {
              sent++;
              yield List<int>.filled(64 << 10, 1);
            }
          }

          return http.StreamedResponse(body(), status, contentLength: length);
        });
    return () => sent;
  }

  test('a small file is read whole', () async {
    serve(4);
    final b = await Dedupe.fetchCapped('https://i.redd.it/a.jpg', 1 << 20);
    expect(b!.length, 4 * (64 << 10));
  });

  test('a file stated as too big is not read at all', () async {
    final s = serve(1000, length: 1000 * (64 << 10));
    expect(await Dedupe.fetchCapped('https://i.redd.it/a.gif', 2 << 20), isNull);
    await pumpEventQueue();
    expect(s(), 0);
  });

  test('a file of unknown size stops once past the cap, long before its end', () async {
    final s = serve(1000); // about 64 MB, no stated size
    expect(await Dedupe.fetchCapped('https://i.redd.it/a.gif', 2 << 20), isNull);
    await pumpEventQueue();
    expect(s(), lessThan(60), reason: 'stopped near 2 MB (33 chunks), not after 1000');
  });

  test('errors and empty replies give nothing', () async {
    serve(4, status: 404);
    expect(await Dedupe.fetchCapped('https://i.redd.it/a.jpg', 1 << 20), isNull);
    serve(0);
    expect(await Dedupe.fetchCapped('https://i.redd.it/a.jpg', 1 << 20), isNull);
  });

  test('video addresses are not hashed as pictures', () {
    expect(Dedupe.hashable('https://i.redd.it/a.jpg'), isTrue);
    expect(Dedupe.hashable('https://i.redd.it/a.gif'), isTrue);
    expect(Dedupe.hashable('https://preview.redd.it/a.jpg?width=140&format=pjpg'), isTrue);
    expect(Dedupe.hashable('https://v.redd.it/abc/DASH_720.mp4'), isFalse);
    expect(Dedupe.hashable('https://i.imgur.com/x.mp4?1'), isFalse);
    expect(Dedupe.hashable('https://v.redd.it/abc/HLSPlaylist.m3u8'), isFalse);
  });
}
