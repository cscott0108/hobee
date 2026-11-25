import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/net_guard.dart';

void main() {
  const home = TrustedNet('HomeNet', 'aa:bb:cc:dd:ee:01', label: 'Home');
  const homeWifi = NetInfo(NetType.wifi, ssid: 'HomeNet', bssid: 'aa:bb:cc:dd:ee:01', handle: 100);
  const lookAlike = NetInfo(NetType.wifi, ssid: 'HomeNet', bssid: '12:34:56:78:9a:bc', handle: 200);
  const cafe = NetInfo(NetType.wifi, ssid: 'Cafe Guest', bssid: '00:11:22:33:44:55', handle: 300);
  const hidden = NetInfo(NetType.wifi, handle: 400); // no location permission: Android hides name and router
  const cell = NetInfo(NetType.cellular, handle: 500);

  NetDecision d(NetInfo? n, {bool on = true, UntrustedWifi u = UntrustedWifi.pause, bool mobile = true, NetInfo? once}) =>
      NetGuard.decide(on: on, net: n, trustedNets: const [home], onUntrusted: u, mobileOk: mobile, once: once);

  tearDown(NetGuard.debugReset);

  test('off (the default): everything is allowed, as before', () {
    for (final n in [homeWifi, lookAlike, cafe, hidden, cell]) {
      expect(d(n, on: false), NetDecision.allow);
    }
  });

  test('a trusted network needs both the name and the router id', () {
    expect(d(homeWifi), NetDecision.allow);
    expect(d(lookAlike), NetDecision.pause, reason: 'same name, different router: a look-alike is not trusted');
    expect(d(hidden), NetDecision.pause, reason: 'name hidden (no permission): fail closed');
    expect(home.matches(const NetInfo(NetType.wifi, ssid: 'HomeNet', bssid: 'AA:BB:CC:DD:EE:01'.toLowerCase())), isTrue);
    expect(home.matches(const NetInfo(NetType.wifi, ssid: 'homenet', bssid: 'aa:bb:cc:dd:ee:01')), isFalse, reason: 'names are exact');
  });

  test('untrusted Wi-Fi follows the chosen action', () {
    expect(d(cafe), NetDecision.pause, reason: 'pause is the default');
    expect(d(cafe, u: UntrustedWifi.mobileData), NetDecision.mobileData);
    expect(d(cafe, u: UntrustedWifi.mobileData, mobile: false), NetDecision.pause, reason: 'mobile data not allowed: pause');
    expect(d(cafe, u: UntrustedWifi.allow), NetDecision.allow);
  });

  test('"Use once" allows only that connection', () {
    expect(d(cafe, once: cafe), NetDecision.allow);
    expect(d(lookAlike, once: cafe), NetDecision.pause);
    expect(d(const NetInfo(NetType.wifi, ssid: 'Cafe Guest', bssid: '00:11:22:33:44:55', handle: 301), once: cafe), NetDecision.pause,
        reason: 'rejoining later is a new connection');
  });

  test('mobile data has its own switch; offline and VPN are left alone', () {
    expect(d(cell), NetDecision.allow);
    expect(d(cell, mobile: false), NetDecision.pause);
    expect(d(const NetInfo(NetType.none)), NetDecision.allow);
    expect(d(const NetInfo(NetType.vpn)), NetDecision.allow);
    expect(d(null), NetDecision.allow);
  });

  test('background refresh: only on the connection last seen trusted, or mobile data if allowed', () {
    bool bg(NetInfo n, {int? handle = 100, bool mobile = true, bool on = true}) =>
        NetGuard.backgroundAllowed(on: on, net: n, trustedHandle: handle, mobileOk: mobile);
    expect(bg(hidden), isFalse, reason: 'a Wi-Fi it cannot identify');
    expect(bg(const NetInfo(NetType.wifi, handle: 100)), isTrue, reason: 'same connection as the trusted one (name not needed)');
    expect(bg(const NetInfo(NetType.wifi, handle: 100), handle: null), isFalse);
    expect(bg(cell), isTrue);
    expect(bg(cell, mobile: false), isFalse);
    expect(bg(hidden, on: false), isTrue, reason: 'Wi-Fi safety off');
  });

  test('paused requests are sent nowhere; allowed ones go direct', () {
    final u = Uri.parse('https://arctic-shift.photon-reddit.com/api/posts/search');
    expect(GuardedHttp.proxyFor(u), 'DIRECT');
    NetGuard.decision.value = NetDecision.pause;
    expect(GuardedHttp.proxyFor(u), GuardedHttp.blockedProxy);
    NetGuard.decision.value = NetDecision.mobileData; // waiting for mobile data
    expect(NetGuard.paused, isTrue);
    NetGuard.onMobileData.value = true;
    expect(GuardedHttp.proxyFor(u), 'DIRECT', reason: 'Android routes it over mobile data');
  });

  test('trusted list survives a save and load, router ids compared without case', () {
    final j = home.toJson();
    final back = TrustedNet.fromJson({...j, 'bssid': 'AA:BB:CC:DD:EE:01'})!;
    expect(back.matches(homeWifi), isTrue);
    expect(back.label, 'Home');
    expect(TrustedNet.fromJson({'name': 'x'}), isNull);
  });

  test('another access point of a trusted name is recognised (to offer adding it)', () {
    NetGuard.trusted.value = const [home];
    expect(NetGuard.sameNameOnly(lookAlike), home);
    expect(NetGuard.sameNameOnly(homeWifi), isNull);
    expect(NetGuard.sameNameOnly(cafe), isNull);
  });
}
