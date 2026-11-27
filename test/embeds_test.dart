import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hobee/embeds.dart';
import 'package:hobee/models.dart';
import 'package:hobee/player.dart';

void main() {
  test('redgifs ids', () {
    expect(Embeds.redgifsId('https://www.redgifs.com/watch/shrillwastefulstarfish'), 'shrillwastefulstarfish');
    expect(Embeds.redgifsId('https://redgifs.com/watch/ShrillWastefulStarfish?x=1'), 'shrillwastefulstarfish');
    expect(Embeds.redgifsId('https://v3.redgifs.com/watch/abcdef'), 'abcdef');
    expect(Embeds.redgifsId('https://www.redgifs.com/ifr/abcdef'), 'abcdef');
    expect(Embeds.redgifsId('https://i.redgifs.com/i/abcdef.jpg'), 'abcdef');
    expect(Embeds.redgifsId('https://media.redgifs.com/AbcDef-mobile.mp4'), 'abcdef');
    expect(Embeds.redgifsId('https://imgur.com/abc'), null);
    expect(Embeds.redgifsId('https://www.redgifs.com/users/someone'), null);
    expect(Embeds.needsResolve('https://media.redgifs.com/AbcDef.mp4'), false);
    expect(Embeds.needsResolve('https://redgifs.com/watch/abcdef'), true);
  });
  test('streamable and v.redd.it', () {
    expect(Embeds.streamableId('https://streamable.com/moo'), 'moo');
    expect(Embeds.streamableId('https://streamable.com/e/moo'), 'moo');
    expect(Embeds.redditHls('https://v.redd.it/abc123/DASH_720.mp4?source=fallback'), 'https://v.redd.it/abc123/HLSPlaylist.m3u8');
    expect(Embeds.redditHls('https://i.redd.it/x.jpg'), null);
  });
  test('posts map to playable video items', () {
    final rg = parseMedia({'url': 'https://redgifs.com/watch/abcdef', 'thumbnail': 'https://t/x.jpg',
      'preview': {'reddit_video_preview': {'fallback_url': 'https://v.redd.it/zz/DASH_480.mp4'}}});
    expect(rg.single.type, MediaType.video);
    expect(rg.single.preview, 'https://v.redd.it/zz/DASH_480.mp4');
    final rv = parseMedia({'url': 'https://v.redd.it/abc', 'media': {'reddit_video': {'fallback_url': 'https://v.redd.it/abc/DASH_720.mp4'}}});
    expect(rv.single.hls, 'https://v.redd.it/abc/HLSPlaylist.m3u8');
    final gv = parseMedia({'url': 'https://i.imgur.com/abc.gifv'});
    expect(gv.single.url, 'https://i.imgur.com/abc.mp4');
  });
  test('resolved RedGIFs links expire, and a fresh lookup gets a new token and link', () async {
    var tokens = 0, gifs = 0;
    var now = DateTime(2026, 1, 1, 12);
    Embeds.clock = () => now;
    Embeds.client = MockClient((r) async {
      if (r.url.path.endsWith('/auth/temporary')) {
        tokens++;
        return http.Response(jsonEncode({'token': 'x.e30.y'}), 200);
      }
      gifs++;
      return http.Response(jsonEncode({'gif': {'urls': {'hd': 'https://media.redgifs.com/Abc.mp4?sig=$gifs'}}}), 200);
    });
    const u = 'https://www.redgifs.com/watch/abcxyz';
    expect(await Embeds.playable(u), 'https://media.redgifs.com/Abc.mp4?sig=1');
    expect(await Embeds.playable(u), 'https://media.redgifs.com/Abc.mp4?sig=1', reason: 'saved for a while');
    expect(gifs, 1);
    now = now.add(const Duration(minutes: 61));
    expect(await Embeds.playable(u), 'https://media.redgifs.com/Abc.mp4?sig=2', reason: 'an old signed link is asked for again');
    final before = tokens;
    expect(await Embeds.playable(u, fresh: true), 'https://media.redgifs.com/Abc.mp4?sig=3');
    expect(tokens, before + 1, reason: 'fresh also gets a new token');
    // A RedGIFs .mp4 link is played as is, unless asked fresh.
    const mp4 = 'https://media.redgifs.com/Abcxyz.mp4';
    expect(await Embeds.playable(mp4), mp4);
    expect(await Embeds.playable(mp4, fresh: true), 'https://media.redgifs.com/Abc.mp4?sig=4');
    Embeds.clock = DateTime.now;
    Embeds.client = http.Client();
  });
  test('video error text names hosts and codes, and calls all-refused removed', () {
    expect(videoErrorText(const [('v.redd.it', 403), ('v.redd.it', 403)]), ('Removed from its host', 'v.redd.it refused it (403)'));
    expect(videoErrorText(const [('media.redgifs.com', 403), ('api.redgifs.com', 410)]).$1, 'Removed from its host');
    final mixed = videoErrorText(const [('v.redd.it', null), ('v.redd.it', 403)]);
    expect(mixed.$1, "Can't play this one", reason: 'no answer may just be the network');
    expect(mixed.$2, 'v.redd.it: no answer\nv.redd.it refused it (403)');
    expect(videoErrorText(const [('i.imgur.com', 206)]).$2, "i.imgur.com answered, but the video wouldn't open");
    expect(videoErrorText(const []).$2, 'No playable copy found');
    expect(hostOf('https://v.redd.it/abc/HLSPlaylist.m3u8'), 'v.redd.it');
  });
  test('time format', () {
    expect(fmtDur(const Duration(seconds: 65)), '1:05');
    expect(fmtDur(const Duration(hours: 1, seconds: 5)), '1:00:05');
  });
}
