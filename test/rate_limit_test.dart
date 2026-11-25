import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';

void main() {
  final now = DateTime.utc(2026, 11, 25, 12);

  test("a 429's reset time comes from the server's headers, capped", () {
    final at = now.add(const Duration(seconds: 7)).millisecondsSinceEpoch;
    expect(Archive.resetTime({'x-ratelimit-reset-at': '$at'}, now: now), now.add(const Duration(seconds: 7)));
    expect(Archive.resetTime({'x-ratelimit-reset': '3'}, now: now), now.add(const Duration(seconds: 3)));
    expect(Archive.resetTime({'x-ratelimit-reset': '9999'}, now: now), now.add(const Duration(seconds: 60)), reason: 'capped');
    expect(Archive.resetTime({'x-ratelimit-reset-at': '1'}, now: now), now, reason: 'already passed');
    expect(Archive.resetTime(const {}, now: now), isNull);
  });
}
