import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'net_guard.dart';

/// Android only shows an app the Wi-Fi name and router id with location permission. Asked only from Wi-Fi
/// safety; the location itself is never read.
Future<bool> askWifiNamePermission() async {
  var ok = false;
  try {
    ok = (await Permission.locationWhenInUse.request()).isGranted;
  } catch (_) {}
  await NetGuard.refresh();
  return ok;
}

String netLabel(NetInfo? i) {
  if (i == null || i.type == NetType.none) return 'Offline';
  return switch (i.type) {
    NetType.wifi => '${i.ssid == null ? 'Wi-Fi (name hidden)' : 'Wi-Fi "${i.ssid}"'}${i.vpn ? ' + VPN' : ''}',
    NetType.cellular => 'Mobile data',
    NetType.vpn => 'VPN',
    NetType.ethernet => 'Ethernet',
    _ => 'Network',
  };
}

/// Top banner while Wi-Fi safety holds Hobees back (or routes it over mobile data). Wraps the whole app.
class NetBanner extends StatelessWidget {
  final Widget child;
  const NetBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([NetGuard.enabled, NetGuard.decision, NetGuard.onMobileData, NetGuard.current]),
        builder: (context, _) {
          final on = NetGuard.enabled.value;
          final paused = on && NetGuard.paused;
          final viaMobile = on && NetGuard.decision.value == NetDecision.mobileData && NetGuard.onMobileData.value;
          if (!paused && !viaMobile) return child;
          return Column(children: [
            _Bar(paused: paused),
            Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: child)),
          ]);
        },
      );
}

class _Bar extends StatelessWidget {
  final bool paused;
  const _Bar({required this.paused});

  @override
  Widget build(BuildContext context) {
    final i = NetGuard.current.value;
    final wifi = i?.type == NetType.wifi;
    final other = NetGuard.sameNameOnly(i);
    final text = !paused
        ? 'Untrusted Wi-Fi: Hobees is using mobile data'
        : !wifi
            ? 'Mobile data is off for Hobees: paused'
            : NetGuard.decision.value == NetDecision.mobileData
                ? (i?.vpn ?? false)
                    ? 'Untrusted Wi-Fi: mobile data can\'t be used while a VPN is on, paused'
                    : 'Untrusted Wi-Fi: mobile data isn\'t available, paused'
                : other != null
                    ? 'Another access point of "${other.label.isEmpty ? other.name : other.label}": paused'
                    : '${netLabel(i)} isn\'t trusted: Hobees is paused';
    final btn = TextButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact);
    return Material(
      key: const Key('net-banner'),
      color: paused ? Colors.deepOrange.shade800 : Colors.blueGrey.shade700,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(paused ? Icons.wifi_off : Icons.signal_cellular_alt, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13))),
            ]),
            if (paused && wifi)
              Wrap(alignment: WrapAlignment.end, children: [
                TextButton(key: const Key('net-once'), style: btn, onPressed: NetGuard.useOnce, child: const Text('Use once')),
                if (NetGuard.mobileData.value && NetGuard.decision.value != NetDecision.mobileData)
                  TextButton(
                      key: const Key('net-mobile'),
                      style: btn,
                      onPressed: NetGuard.mobileOnce,
                      child: const Text('Use mobile data')),
                if (i?.ssid == null)
                  TextButton(key: const Key('net-permission'), style: btn, onPressed: askWifiNamePermission, child: const Text('Show Wi-Fi name'))
                else
                  TextButton(
                      key: const Key('net-trust'),
                      style: btn,
                      onPressed: () => NetGuard.trustCurrent(label: other?.label ?? ''),
                      child: Text(other != null ? 'Add access point' : 'Trust')),
              ]),
          ]),
        ),
      ),
    );
  }
}

/// Settings entry.
class NetworkSettingsTile extends StatelessWidget {
  const NetworkSettingsTile({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: NetGuard.enabled,
        builder: (_, on, _) => ListTile(
          key: const Key('open-network'),
          leading: const Icon(Icons.wifi_lock),
          title: const Text('Wi-Fi safety'),
          subtitle: Text(on ? 'On: pauses on Wi-Fi you haven\'t trusted' : 'Off'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NetworkSettingsScreen())),
        ),
      );
}

class NetworkSettingsScreen extends StatelessWidget {
  const NetworkSettingsScreen({super.key});

  Future<void> _rename(BuildContext context, TrustedNet t) async {
    final c = TextEditingController(text: t.label);
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Name this network'),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: t.name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (v != null) NetGuard.relabel(t, v);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Wi-Fi safety')),
        body: ListenableBuilder(
          listenable: Listenable.merge(
              [NetGuard.enabled, NetGuard.untrusted, NetGuard.mobileData, NetGuard.vpnSafe, NetGuard.trusted, NetGuard.current, NetGuard.decision]),
          builder: (context, _) {
            final i = NetGuard.current.value;
            final trustedNow = i != null && NetGuard.trusted.value.any((t) => t.matches(i));
            final other = NetGuard.sameNameOnly(i);
            return ListView(children: [
              SwitchListTile(
                key: const Key('net-safety'),
                title: const Text('Wi-Fi safety'),
                subtitle: const Text('On Wi-Fi you haven\'t trusted, Hobees doesn\'t go online by itself. '
                    'Trusting a network saves its name and its router\'s id, so a look-alike with the same name isn\'t trusted.'),
                value: NetGuard.enabled.value,
                onChanged: (v) async {
                  if (v) await askWifiNamePermission();
                  NetGuard.enabled.value = v;
                },
              ),
              ListTile(
                key: const Key('net-current'),
                leading: Icon(i?.type == NetType.cellular ? Icons.signal_cellular_alt : Icons.wifi),
                title: Text(netLabel(i)),
                subtitle: Text(i?.type != NetType.wifi
                    ? (i?.type == NetType.cellular ? (NetGuard.mobileData.value ? 'Allowed' : 'Paused') : '')
                    : trustedNow
                        ? 'Trusted'
                        : i?.ssid == null
                            ? 'Android hides the Wi-Fi name until Hobees has location permission (and location is on). The location itself is never read.'
                            : other != null
                                ? 'Another access point of "${other.label.isEmpty ? other.name : other.label}" (routers use a different id for each band). Add it if it is yours.'
                                : 'Not trusted'),
                trailing: i?.type != NetType.wifi || trustedNow
                    ? null
                    : i?.ssid == null
                        ? TextButton(onPressed: askWifiNamePermission, child: const Text('Allow'))
                        : TextButton(
                            key: const Key('net-trust-here'),
                            onPressed: () => NetGuard.trustCurrent(label: other?.label ?? ''),
                            child: Text(other != null ? 'Add' : 'Trust')),
              ),
              const Divider(),
              const ListTile(dense: true, title: Text('Trusted networks')),
              if (NetGuard.trusted.value.isEmpty)
                const ListTile(dense: true, subtitle: Text('None yet. Connect to your home Wi-Fi and tap Trust.')),
              for (final t in NetGuard.trusted.value)
                ListTile(
                  title: Text(t.label.isEmpty ? t.name : t.label),
                  subtitle: Text('${t.name} · router ${t.bssid}'),
                  onTap: () => _rename(context, t),
                  trailing: IconButton(tooltip: 'Forget', icon: const Icon(Icons.delete_outline), onPressed: () => NetGuard.forget(t)),
                ),
              const Divider(),
              ListTile(
                title: const Text('On other Wi-Fi'),
                trailing: DropdownButton<UntrustedWifi>(
                  key: const Key('net-untrusted'),
                  value: NetGuard.untrusted.value,
                  items: const [
                    DropdownMenuItem(value: UntrustedWifi.pause, child: Text('Pause')),
                    DropdownMenuItem(value: UntrustedWifi.mobileData, child: Text('Use mobile data')),
                    DropdownMenuItem(value: UntrustedWifi.allow, child: Text('Allow')),
                  ],
                  onChanged: (v) => NetGuard.untrusted.value = v ?? UntrustedWifi.pause,
                ),
              ),
              SwitchListTile(
                key: const Key('net-vpn-safe'),
                title: const Text('A VPN counts as safe'),
                subtitle: const Text('While a VPN is connected, Hobees works on any network: the network only sees encrypted '
                    'traffic. If the VPN drops, the rules above apply again.'),
                value: NetGuard.vpnSafe.value,
                onChanged: (v) => NetGuard.vpnSafe.value = v,
              ),
              SwitchListTile(
                key: const Key('net-mobile-ok'),
                title: const Text('Use mobile data'),
                subtitle: const Text('Off: Hobees also pauses on mobile data. "Use mobile data" on other Wi-Fi sends only Hobees\' '
                    'traffic over mobile data; the rest of the phone stays on the Wi-Fi.'),
                value: NetGuard.mobileData.value,
                onChanged: (v) => NetGuard.mobileData.value = v,
              ),
              const ListTile(
                dense: true,
                subtitle: Text('Background refresh only runs on the connection Hobees last saw as trusted, or on mobile data if '
                    'allowed. It never reads the Wi-Fi name in the background, so no "location all the time" permission.'),
              ),
            ]);
          },
        ),
      );
}
