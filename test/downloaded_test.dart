import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/downloaded.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await (await Db.db).delete('downloads');
    Downloaded.urls.value = const {};
  });

  test('a download is marked at once and remembered after a restart', () async {
    expect(Downloaded.has('https://i.redd.it/a.jpg'), isFalse);
    await Downloaded.mark('https://i.redd.it/a.jpg', 'p1');
    expect(Downloaded.has('https://i.redd.it/a.jpg'), isTrue);
    Downloaded.urls.value = const {}; // app restart
    await Downloaded.load();
    expect(Downloaded.has('https://i.redd.it/a.jpg'), isTrue);
    expect(Downloaded.has('https://i.redd.it/b.jpg'), isFalse);
  });

  test('marking twice is fine', () async {
    await Downloaded.mark('u', 'p');
    await Downloaded.mark('u', 'p');
    expect(await (await Db.db).query('downloads'), hasLength(1));
  });
}
