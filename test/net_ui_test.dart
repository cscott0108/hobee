import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/net_guard.dart';
import 'package:hobee/net_ui.dart';

void main() {
  const net = MethodChannel('hobee/net');
  Map<String, Object?> here = {};

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    NetGuard.debugReset();
    here = {'type': 'wifi', 'ssid': 'Cafe Guest', 'bssid': '00:11:22:33:44:55', 'handle': 300};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(net, (c) async {
      if (c.method == 'current') return here;
      if (c.method == 'bindCellular') return true;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(net, null);
    NetGuard.debugReset();
  });

  Future<void> app(WidgetTester t) async {
    NetGuard.enabled.value = true;
    await NetGuard.refresh();
    await t.pumpWidget(MaterialApp(builder: (_, child) => NetBanner(child: child!), home: const Scaffold(body: Text('feed'))));
    await t.pump();
  }

  testWidgets('untrusted Wi-Fi: banner says paused; Use once lets this connection through', (t) async {
    await app(t);
    expect(NetGuard.paused, isTrue);
    expect(find.textContaining('isn\'t trusted'), findsOneWidget);
    expect(find.text('feed'), findsOneWidget, reason: 'the app stays usable (cached posts, gallery)');
    await t.tap(find.byKey(const Key('net-once')));
    await t.pump();
    await t.pump();
    expect(NetGuard.paused, isFalse);
    expect(find.byKey(const Key('net-banner')), findsNothing);
  });

  testWidgets('Trust adds the network (name + router) and the banner goes away', (t) async {
    await app(t);
    await t.tap(find.byKey(const Key('net-trust')));
    await t.pump();
    await t.pump();
    expect(NetGuard.trusted.value.single.name, 'Cafe Guest');
    expect(NetGuard.trusted.value.single.bssid, '00:11:22:33:44:55');
    expect(find.byKey(const Key('net-banner')), findsNothing);
  });

  testWidgets('Use mobile data routes Hobees over mobile data and says so', (t) async {
    await app(t);
    await t.tap(find.byKey(const Key('net-mobile')));
    await t.pump();
    await t.pump();
    expect(NetGuard.onMobileData.value, isTrue);
    expect(NetGuard.paused, isFalse);
    expect(find.textContaining('using mobile data'), findsOneWidget);
  });

  testWidgets('name hidden (no location permission): no Trust button, offers to show the name', (t) async {
    here = {'type': 'wifi', 'handle': 400};
    await app(t);
    expect(NetGuard.paused, isTrue);
    expect(find.byKey(const Key('net-trust')), findsNothing);
    expect(find.byKey(const Key('net-permission')), findsOneWidget);
  });

  testWidgets('off: no banner on any network', (t) async {
    await t.pumpWidget(MaterialApp(builder: (_, child) => NetBanner(child: child!), home: const Scaffold(body: Text('feed'))));
    await NetGuard.refresh();
    await t.pump();
    expect(find.byKey(const Key('net-banner')), findsNothing);
    expect(NetGuard.paused, isFalse);
  });

  testWidgets('settings screen shows the network and trusts it', (t) async {
    NetGuard.enabled.value = true;
    await NetGuard.refresh();
    await t.pumpWidget(const MaterialApp(home: NetworkSettingsScreen()));
    expect(find.text('Wi-Fi "Cafe Guest"'), findsOneWidget);
    expect(find.text('Not trusted'), findsOneWidget);
    await t.tap(find.byKey(const Key('net-trust-here')));
    await t.pump();
    await t.pump();
    expect(find.text('Trusted'), findsOneWidget);
    expect(find.textContaining('Cafe Guest · router 00:11:22:33:44:55'), findsOneWidget);
  });
}
