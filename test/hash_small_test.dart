import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/dedupe.dart';
import 'package:image/image.dart' as img;

/// A [w]x[h] picture of soft blocks from [seed], as a JPEG (or PNG).
Uint8List picture(int seed, {int w = 1200, int h = 900, bool png = false}) {
  final r = Random(seed);
  final cells = List.generate(6 * 8, (_) => r.nextInt(256));
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = cells[(y * 6 ~/ h) * 8 + x * 8 ~/ w];
      im.setPixelRgb(x, y, v, (v * 3 + x) % 256, 255 - v);
    }
  }
  return png ? img.encodePng(im) : img.encodeJpg(im, quality: 85);
}

int bits(int a, int b) {
  var x = a ^ b, n = 0;
  while (x != 0) {
    x &= x - 1;
    n++;
  }
  return n;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => hashDecoder = (b, w) => ui.instantiateImageCodec(b, targetWidth: w));

  test('the small decode gives the old full-size hash, within the duplicate allowance', () async {
    for (final seed in [1, 2, 3, 4, 5]) {
      for (final png in [false, true]) {
        final b = picture(seed, png: png);
        final old = dHash(b)!;
        final now = (await hashBytes(b))!;
        expect(bits(old, now), lessThanOrEqualTo(Dedupe.maxDistance ~/ 2), reason: 'seed $seed png $png');
      }
    }
  });

  test('different pictures still differ by more than the allowance', () async {
    final a = (await hashBytes(picture(1)))!, b = (await hashBytes(picture(2)))!;
    expect(bits(a, b), greaterThan(Dedupe.maxDistance));
  });

  test('pictures are decoded small, never at full size', () async {
    final widths = <int>[];
    hashDecoder = (b, w) {
      widths.add(w);
      return ui.instantiateImageCodec(b, targetWidth: w);
    };
    expect(await hashBytes(picture(3)), isNotNull);
    expect(widths, [hashDecodeWidth]);
    expect(hashDecodeWidth, lessThanOrEqualTo(64));
  });

  test('unreadable bytes give no hash', () async {
    expect(await hashBytes(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });

  test('tiny pictures (narrower than the 9 hash cells) still hash', () {
    final px = Uint8List.fromList([for (var i = 0; i < 4 * 3; i++) ...[i * 20, i * 20, i * 20, 255]]);
    expect(dHashRgba(px, 4, 3), isNotNull);
  });
}
