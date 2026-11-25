import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Wi-Fi safety (Phase 5b): Hobees only goes online by itself on trusted networks. On any other Wi-Fi it
/// fails closed: it pauses (default), routes its own traffic over mobile data, or uses the network if you
/// said so. Off by default. The Android side is the hobee_net plugin (packages/hobee_net).

enum NetType { wifi, cellular, ethernet, vpn, other, none }

/// What the phone is connected to right now. [ssid] and [bssid] (the router's hardware id) are null when
/// Android hides them (no location permission, or location turned off). [handle] is Android's id for this
/// connection; it stays the same until the phone leaves the network.
class NetInfo {
  final NetType type;
  final String? ssid, bssid;
  final int? handle;
  const NetInfo(this.type, {this.ssid, this.bssid, this.handle});

  static NetInfo fromMap(Map<Object?, Object?>? m) {
    final t = NetType.values.asNameMap()[m?['type']] ?? NetType.none;
    return NetInfo(t, ssid: m?['ssid'] as String?, bssid: (m?['bssid'] as String?)?.toLowerCase(), handle: (m?['handle'] as num?)?.toInt());
  }

  /// Same connection as [o] (for "Use once" and change detection).
  bool same(NetInfo? o) => o != null && o.type == type && o.handle == handle && o.ssid == ssid && o.bssid == bssid;
}

/// A trusted Wi-Fi: its name plus one router's hardware id, so a look-alike network with the same name isn't trusted.
class TrustedNet {
  final String name, bssid;
  final String label;
  const TrustedNet(this.name, this.bssid, {this.label = ''});

  bool matches(NetInfo i) => i.type == NetType.wifi && i.ssid == name && i.bssid != null && i.bssid == bssid.toLowerCase();

  Map<String, String> toJson() => {'name': name, 'bssid': bssid, 'label': label};
  static TrustedNet? fromJson(Object? j) => j is Map && j['name'] is String && j['bssid'] is String
      ? TrustedNet(j['name'] as String, (j['bssid'] as String).toLowerCase(), label: j['label'] as String? ?? '')
      : null;
}

/// What to do on a Wi-Fi that isn't trusted.
enum UntrustedWifi { pause, mobileData, allow }

/// The decision for the network the phone is on.
enum NetDecision { allow, pause, mobileData }

class NetGuard {
  static const _ch = MethodChannel('hobee/net');

  static final enabled = ValueNotifier<bool>(false);
  static final untrusted = ValueNotifier<UntrustedWifi>(UntrustedWifi.pause);
  /// Mobile data allowed (directly, and as the way round an untrusted Wi-Fi).
  static final mobileData = ValueNotifier<bool>(true);
  static final trusted = ValueNotifier<List<TrustedNet>>(const []);

  static final current = ValueNotifier<NetInfo?>(null);
  static final decision = ValueNotifier<NetDecision>(NetDecision.allow);
  /// True while Hobees' traffic really goes over mobile data (Android gave us the network).
  static final onMobileData = ValueNotifier<bool>(false);

  /// "Use once": this connection is allowed until the phone leaves it.
  static NetInfo? _once;
  static SharedPreferences? _sp;

  /// Paused: Hobees must not go online. Checked before every web request, video and background run.
  static bool get paused => decision.value == NetDecision.pause || (decision.value == NetDecision.mobileData && !onMobileData.value);

  /// The rule, without side effects.
  static NetDecision decide({
    required bool on,
    required NetInfo? net,
    required List<TrustedNet> trustedNets,
    required UntrustedWifi onUntrusted,
    required bool mobileOk,
    NetInfo? once,
  }) {
    if (!on || net == null) return NetDecision.allow;
    switch (net.type) {
      case NetType.wifi:
        if (trustedNets.any((t) => t.matches(net))) return NetDecision.allow;
        if (once != null && once.same(net)) return NetDecision.allow;
        return switch (onUntrusted) {
          UntrustedWifi.allow => NetDecision.allow,
          UntrustedWifi.mobileData => mobileOk ? NetDecision.mobileData : NetDecision.pause,
          UntrustedWifi.pause => NetDecision.pause,
        };
      case NetType.cellular:
        return mobileOk ? NetDecision.allow : NetDecision.pause;
      case NetType.vpn: // already a tunnel (e.g. SecuRDP); Phase 8 adds its own rules
      case NetType.ethernet:
      case NetType.other:
      case NetType.none: // offline: nothing goes out anyway
        return NetDecision.allow;
    }
  }

  /// Background refresh, which may not read the Wi-Fi name: allowed only on the very connection last seen
  /// trusted while Hobees was open (same Android connection id), or on mobile data if allowed.
  static bool backgroundAllowed({required bool on, required NetInfo net, required int? trustedHandle, required bool mobileOk}) {
    if (!on) return true;
    return switch (net.type) {
      NetType.wifi => trustedHandle != null && net.handle == trustedHandle,
      NetType.cellular => mobileOk,
      NetType.none => false,
      _ => true,
    };
  }

  /// A trusted network with this name exists, but not this router (another access point of a mesh, or a look-alike).
  static TrustedNet? sameNameOnly(NetInfo? i) {
    if (i == null || i.type != NetType.wifi || i.ssid == null) return null;
    if (trusted.value.any((t) => t.matches(i))) return null;
    for (final t in trusted.value) {
      if (t.name == i.ssid) return t;
    }
    return null;
  }

  static Future<void> load() async {
    final sp = _sp = await SharedPreferences.getInstance();
    enabled.value = sp.getBool('netSafety') ?? false;
    untrusted.value = UntrustedWifi.values.asNameMap()[sp.getString('netUntrusted')] ?? UntrustedWifi.pause;
    mobileData.value = sp.getBool('netMobileData') ?? true;
    try {
      trusted.value = [for (final j in jsonDecode(sp.getString('netTrusted') ?? '[]') as List) ?TrustedNet.fromJson(j)];
    } catch (_) {
      trusted.value = const [];
    }
    enabled.addListener(() => sp.setBool('netSafety', enabled.value));
    untrusted.addListener(() => sp.setString('netUntrusted', untrusted.value.name));
    mobileData.addListener(() => sp.setBool('netMobileData', mobileData.value));
    trusted.addListener(() => sp.setString('netTrusted', jsonEncode([for (final t in trusted.value) t.toJson()])));
    for (final n in [enabled, untrusted, mobileData, trusted]) {
      n.addListener(() => unawaited(refresh()));
    }
    HttpOverrides.global = GuardedHttp();
    _ch.setMethodCallHandler((c) async {
      if (c.method == 'changed') _changedSoon();
    });
    try {
      await _ch.invokeMethod('watch');
    } catch (_) {}
    await refresh();
  }

  static Timer? _debounce;
  static void _changedSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => unawaited(refresh()));
  }

  static Future<NetInfo?> read() async {
    try {
      return NetInfo.fromMap(await _ch.invokeMapMethod<Object?, Object?>('current'));
    } catch (_) {
      return null;
    }
  }

  /// Re-reads the network and applies the decision (pause, mobile data or allow).
  static Future<void> refresh() async {
    final net = await read();
    if (_once != null && !_once!.same(net)) _once = null; // left the network: "Use once" ends
    current.value = net;
    final d = decide(on: enabled.value, net: net, trustedNets: trusted.value, onUntrusted: untrusted.value, mobileOk: mobileData.value, once: _once);
    if (enabled.value && net != null && net.type == NetType.wifi && trusted.value.any((t) => t.matches(net))) {
      await _sp?.setInt('netTrustedHandle', net.handle ?? -1); // for the background refresh (see [backgroundAllowed])
    }
    if (d == NetDecision.mobileData) {
      if (!onMobileData.value || decision.value != d) {
        decision.value = d;
        var ok = false;
        try {
          ok = await _ch.invokeMethod<bool>('bindCellular') ?? false;
        } catch (_) {}
        onMobileData.value = ok; // not available: stays paused (fail closed)
      }
    } else {
      if (onMobileData.value) {
        try {
          await _ch.invokeMethod('unbind');
        } catch (_) {}
        onMobileData.value = false;
      }
      decision.value = d;
    }
  }

  /// Banner "Use once": allow this connection until the phone leaves it.
  static Future<void> useOnce() async {
    _once = current.value;
    await refresh();
  }

  /// Trust the Wi-Fi the phone is on (name + this router's id). False if Android hides them.
  static bool trustCurrent({String label = ''}) {
    final i = current.value;
    if (i == null || i.type != NetType.wifi || i.ssid == null || i.bssid == null) return false;
    if (trusted.value.any((t) => t.matches(i))) return true;
    trusted.value = [...trusted.value, TrustedNet(i.ssid!, i.bssid!, label: label)];
    return true;
  }

  static void forget(TrustedNet t) => trusted.value = [for (final x in trusted.value) if (!identical(x, t)) x];

  static void relabel(TrustedNet t, String label) =>
      trusted.value = [for (final x in trusted.value) identical(x, t) ? TrustedNet(x.name, x.bssid, label: label) : x];

  /// For the background isolate: may this run go online now?
  static Future<bool> backgroundOk() async {
    final sp = await SharedPreferences.getInstance();
    if (!(sp.getBool('netSafety') ?? false)) return true;
    final net = await read();
    if (net == null) return false;
    return backgroundAllowed(on: true, net: net, trustedHandle: sp.getInt('netTrustedHandle'), mobileOk: sp.getBool('netMobileData') ?? true);
  }

  @visibleForTesting
  static void debugReset() {
    enabled.value = false;
    untrusted.value = UntrustedWifi.pause;
    mobileData.value = true;
    trusted.value = const [];
    current.value = null;
    decision.value = NetDecision.allow;
    onMobileData.value = false;
    _once = null;
  }
}

/// Thrown instead of loading while Wi-Fi safety has paused Hobees (the grid shows it with Retry).
class NetPausedException implements Exception {
  const NetPausedException();
  @override
  String toString() => 'Paused on an untrusted Wi-Fi. Use the banner at the top to continue.';
}

/// Every Dart web request (feeds, archive, images, downloads) goes through here. While Hobees is paused it is
/// sent to a closed local port, so it fails at once instead of quietly using an untrusted network.
class GuardedHttp extends HttpOverrides {
  static const blockedProxy = 'PROXY 127.0.0.1:9';

  /// The proxy rule for one request (the gate itself).
  static String proxyFor(Uri _) => NetGuard.paused ? blockedProxy : 'DIRECT';

  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)..findProxy = proxyFor;
}
