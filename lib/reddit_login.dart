import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'follows.dart';
import 'reddit_session.dart';

/// Opens Reddit's own login page after a one-time warning.
Future<void> startSessionLogin(BuildContext context) async {
  if (!await RedditSession.warned()) {
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Log in with your Reddit session?'),
        content: const SingleChildScrollView(
          child: Text('You log in on Reddit\'s own page. Hobees never sees your password; it keeps only the session '
              'cookie Reddit sets, encrypted and covered by the app lock.\n\n'
              'Reddit wants apps to use its official login (Settings → client ID). A website session used by an app '
              'can stop working whenever Reddit changes its site, and Reddit could flag the account. Hobees still '
              'says it\'s Hobees on every request.\n\n'
              'Following and Deep Search keep working without it, and are used again if the session ends.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(key: const Key('session-accept'), onPressed: () => Navigator.pop(d, true), child: const Text('I understand, continue')),
        ],
      ),
    );
    if (ok != true) return;
    await RedditSession.setWarned();
  }
  if (!context.mounted) return;
  await Navigator.push(context, MaterialPageRoute(builder: (_) => const RedditLoginScreen()));
}

/// Reddit's login page in an in-app browser. As soon as Reddit sets its session cookie, Hobees keeps that one
/// value and wipes the browser's cookies and storage, so no second copy stays behind.
class RedditLoginScreen extends StatefulWidget {
  const RedditLoginScreen({super.key});
  @override
  State<RedditLoginScreen> createState() => _RedditLoginScreenState();
}

class _RedditLoginScreenState extends State<RedditLoginScreen> {
  WebViewController? c;
  Timer? poll;
  bool done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await WebViewCookieManager().clearCookies(); // start clean: never pick up an older session
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) => _check(), onUrlChange: (_) => _check()));
    await ctrl.loadRequest(Uri.parse('https://www.reddit.com/login/'));
    if (!mounted) return;
    setState(() => c = ctrl);
    // Reddit's login finishes without always loading a new page, so also look every second and a half.
    poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _check());
  }

  Future<void> _check() async {
    if (done) return;
    final v = RedditSession.pick(await RedditSession.webCookies());
    if (v == null || done || !mounted) return;
    done = true;
    poll?.cancel();
    await RedditSession.save(v);
    await _wipe();
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(SnackBar(content: Text('Logged in${RedditSession.username.value == null ? '' : ' as u/${RedditSession.username.value}'}')));
  }

  Future<void> _wipe() async {
    try {
      await WebViewCookieManager().clearCookies();
      await c?.clearCache();
      await c?.clearLocalStorage();
    } catch (_) {}
  }

  @override
  void dispose() {
    poll?.cancel();
    if (!done) _wipe(); // a login you left half way leaves nothing behind
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Log in on reddit.com')),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: cs.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('Type your Reddit username and password on Reddit\'s page below. Hobees keeps only the session '
              'cookie. Google and Apple sign-in don\'t work in apps; use your Reddit password.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ),
        Expanded(child: c == null ? const Center(child: CircularProgressIndicator()) : WebViewWidget(controller: c!)),
      ]),
    );
  }
}

/// Settings section for the session login.
class RedditSessionSettings extends StatelessWidget {
  const RedditSessionSettings({super.key});

  Future<void> _import(BuildContext context) async {
    final m = ScaffoldMessenger.of(context);
    final lists = await FollowStore.profiles();
    if (!context.mounted) return;
    final pid = await showDialog<int>(
      context: context,
      builder: (d) => SimpleDialog(title: const Text('Add your subscriptions to'), children: [
        for (final p in lists) SimpleDialogOption(key: Key('import-to-${p.id}'), onPressed: () => Navigator.pop(d, p.id), child: Text(p.name)),
      ]),
    );
    if (pid == null) return;
    try {
      final subs = await RedditSession.subscriptions();
      final n = await FollowStore.add(pid, [for (final s in subs) Follow(FollowKind.sub, s)]);
      m.showSnackBar(SnackBar(content: Text('Added $n of ${subs.length} subscribed subreddits')));
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([RedditSession.cookie, RedditSession.username, RedditSession.ended]),
        builder: (context, _) {
          final has = RedditSession.cookie.value != null;
          final ended = RedditSession.ended.value;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              key: const Key('session-tile'),
              leading: const Icon(Icons.cookie_outlined),
              title: Text(!has
                  ? 'Reddit session: not logged in'
                  : ended
                      ? 'Reddit session ended'
                      : 'Reddit session: u/${RedditSession.username.value ?? '…'}'),
              subtitle: Text(!has
                  ? 'Log in on Reddit\'s own page, no client ID needed. Opt-in.'
                  : ended
                      ? 'Reddit stopped accepting it. Log in again, or carry on without login.'
                      : 'Used for Home when the client-ID login isn\'t set up.'),
              trailing: has && !ended
                  ? TextButton(key: const Key('session-logout'), onPressed: RedditSession.logout, child: const Text('Log out'))
                  : FilledButton(key: const Key('session-login'), onPressed: () => startSessionLogin(context), child: Text(ended ? 'Log in again' : 'Log in')),
            ),
            if (has && !ended)
              ListTile(
                key: const Key('session-import'),
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                dense: true,
                title: const Text('Import my subscriptions'),
                subtitle: const Text('Adds the subreddits you subscribe to on Reddit to a Following list'),
                onTap: () => _import(context),
              ),
          ]);
        },
      );
}
