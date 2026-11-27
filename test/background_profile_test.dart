import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/app_lock.dart';
import 'package:hobee/background.dart';
import 'package:hobee/space.dart';
import 'package:hobee/start_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<String> calls;
  late Map<String, String> store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    store = {};
    BackgroundRefresh.register = (name, input, every, c) async => calls.add('register $name ${input['space']}');
    BackgroundRefresh.cancel = (name) async => calls.add('cancel $name');
    StartLock.read = (k) async => store[k];
  });
  tearDown(() {
    BackgroundRefresh.enabled.value = false;
    Space.debugReset();
  });

  test('your profile keeps its task; the panic profile has its own', () async {
    BackgroundRefresh.enabled.value = true;
    await BackgroundRefresh.schedule();
    BackgroundRefresh.enabled.value = false;
    await BackgroundRefresh.schedule();
    expect(calls, ['register hobees.following.refresh 0', 'cancel hobees.following.refresh']);
  });

  test("the panic profile's refresh setting never touches yours", () async {
    Space.open(1);
    await BackgroundRefresh.schedule(); // off by default there
    BackgroundRefresh.enabled.value = true;
    await BackgroundRefresh.schedule();
    expect(calls, ['cancel hobees.following.refresh.p1', 'register hobees.following.refresh.p1 1']);
  });

  test('a background task opens the profile it belongs to', () async {
    expect(await BackgroundRefresh.openProfile(null), isTrue, reason: 'tasks from before have no profile: yours');
    expect(Space.id, 0);
    store[StartLock.realKey] = hashPin('1111', iterations: 10);
    store[StartLock.panicKey] = hashPin('2222', iterations: 10);
    expect(await BackgroundRefresh.openProfile({'space': 1}), isTrue);
    expect(Space.id, 1);
    expect(calls, isEmpty);
  });

  test("the panic profile's task does nothing once it's off, and is cancelled", () async {
    expect(await BackgroundRefresh.openProfile({'space': 1}), isFalse);
    expect(Space.id, 0);
    expect(calls, ['cancel hobees.following.refresh.p1']);
  });

  test('a switch empties the temp folder before restarting', () async {
    final tmp = await Directory.systemTemp.createTemp('hobees_tmp');
    final note = File('${(await Directory.systemTemp.createTemp('hobees_note')).path}/switch_to');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
      await note.parent.delete(recursive: true);
    });
    await File('${tmp.path}/frames_1.mp4').writeAsString('x');
    await Directory('${tmp.path}/dl').create();
    await File('${tmp.path}/dl/a.jpg').writeAsString('x');
    StartLock.tempDir = () async => tmp;
    StartLock.switchFile = () async => note;
    var tempLeftAtRestart = -1;
    StartLock.restart = () async => tempLeftAtRestart = tmp.listSync().length;
    await StartLock.switchTo(1);
    expect(tempLeftAtRestart, 0);
    expect(note.existsSync(), isTrue, reason: 'the switch note lives elsewhere and survives');
  });
}
