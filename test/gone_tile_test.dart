import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';

void main() {
  NetworkImageLoadException http(int code) => NetworkImageLoadException(statusCode: code, uri: Uri.parse('https://preview.redd.it/x.jpg'));

  test('a deleted picture (404 / 410) counts as gone', () {
    expect(isGoneError(http(404)), isTrue);
    expect(isGoneError(http(410)), isTrue);
  });

  test('offline, rate limits and server errors are not proof it is gone', () {
    expect(isGoneError(http(429)), isFalse);
    expect(isGoneError(http(500)), isFalse);
    expect(isGoneError(http(403)), isFalse);
    expect(isGoneError(Exception('SocketException: Failed host lookup')), isFalse);
  });
}
