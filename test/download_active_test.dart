import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/download.dart';

void main() {
  test('a download shows as active until it ends, even when it fails; a queue shows every item first', () async {
    Downloader.queue(['a', 'b']);
    expect(Downloader.active.value, {'a', 'b'});
    await Downloader.tracking('a', () async {
      expect(Downloader.active.value, contains('a'));
    });
    expect(Downloader.active.value, {'b'});
    await expectLater(Downloader.tracking('b', () async => throw StateError('x')), throwsStateError);
    expect(Downloader.active.value, isEmpty);
  });
}
