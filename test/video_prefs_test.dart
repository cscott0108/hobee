import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/player.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('start paused and mix audio are saved, and muted videos always mix', () async {
    SharedPreferences.setMockInitialValues({});
    await VideoPrefs.load();
    expect(VideoPrefs.startPaused.value, isFalse);
    expect(VideoPrefs.mixAudio.value, isFalse);
    VideoPrefs.muted.value = false;
    expect(VideoPrefs.mixes, isFalse);
    VideoPrefs.muted.value = true;
    expect(VideoPrefs.mixes, isTrue);
    VideoPrefs.muted.value = false;
    VideoPrefs.mixAudio.value = true;
    VideoPrefs.startPaused.value = true;
    expect(VideoPrefs.mixes, isTrue);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('videoMixAudio'), isTrue);
    expect(sp.getBool('videoStartPaused'), isTrue);
  });
}
