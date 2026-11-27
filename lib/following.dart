import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'archive.dart';
import 'background.dart' show BackgroundRefresh;
import 'db.dart';
import 'follows.dart';
import 'models.dart';
import 'pace_log.dart';
import 'sub_search.dart' show isSubSearch, subParts;

/// Following feed (no login): every subreddit and user of a profile, merged by date.
///
/// Source key `fol:<profileId>`. Reddit's own no-login endpoints answer 403/429 and Redlib instances either
/// show a bot check or filter NSFW posts, so posts come from Arctic Shift, one paced request per subreddit or
/// user. Each call does a small batch (so the grid fills in as it goes):
///  1. refresh round: newest posts of every entry not checked in the last [freshFor], stalest first,
///     asking only for posts newer than the newest one already seen;
///  2. fill-back: entries whose loaded posts don't yet reach back [subWindow] (subreddits) or [userWindow]
///     (users) go further back, newest gap first, up to [fillPosts] posts per entry;
///  3. then, when you scroll to the end, paging back one page further per entry.
bool isFollowing(String source) => source.startsWith('fol:');
String followingKey(int profile) => 'fol:$profile';
int? followingProfile(String source) => isFollowing(source) ? int.tryParse(source.substring(4)) : null;

/// Progress line for the status bar, e.g. "Checked 40 of 325 · ~9 min left".
final followingStatus = ValueNotifier<String?>(null);

/// Following feed chips: 0 all, 1 posts in followed subreddits, 2 posts by followed users.
final followingKind = ValueNotifier<int>(0);

class FollowState {
  int at; // last refresh, ms since epoch (0 = never)
  int? newest, oldest; // created_utc range loaded so far
  bool done; // no older posts left
  int n; // posts loaded for this entry so far
  int quiet; // checks in a row that found nothing new
  int fails; // checks in a row that failed
  String? err; // why the last failed check failed
  FollowState({this.at = 0, this.newest, this.oldest, this.done = false, this.n = 0, this.quiet = 0, this.fails = 0, this.err});

  factory FollowState.decode(String? s) {
    if (s == null) return FollowState();
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return FollowState(
          at: m['at'] as int? ?? 0, newest: m['new'] as int?, oldest: m['old'] as int?, done: m['done'] == true, n: m['n'] as int? ?? 0,
          quiet: m['q'] as int? ?? 0, fails: m['f'] as int? ?? 0, err: m['e'] as String?);
    } catch (_) {
      return FollowState();
    }
  }
  String encode() => jsonEncode({'at': at, 'new': ?newest, 'old': ?oldest, 'done': done, 'n': n, if (quiet > 0) 'q': quiet, if (fails > 0) 'f': fails, 'e': ?err});
}

class Following {
  /// Requests per fetchMore call.
  static int budget = 4; // keeps one call well under the grid's 2-minute timeout, even with a cooldown
  static const freshFor = Duration(minutes: 30);
  static const maxRecheck = Duration(hours: 12);

  /// How long an entry rests after a check, learned from how active it is: by the age of its newest post
  /// (posted today: [freshFor]; this week: 2 h; older: [maxRecheck]), and doubled for every check in a row
  /// that found nothing new (30 min, 1 h, 2 h ...), up to [maxRecheck]. Something new resets the streak.
  static Duration recheckAfter(FollowState s, int nowMs) {
    var base = freshFor;
    final n = s.newest;
    if (n != null) {
      final age = Duration(milliseconds: nowMs - n * 1000);
      base = age < const Duration(days: 1) ? freshFor : age < const Duration(days: 7) ? const Duration(hours: 2) : maxRecheck;
    }
    final streak = freshFor * (1 << s.quiet.clamp(0, 5));
    var d = streak > base ? streak : base;
    if (d > maxRecheck) d = maxRecheck;
    // Never sooner than the background refresh interval, so opening (or killing and reopening) the app checks a
    // channel no more often than the background task would.
    final floor = minRest();
    return d < floor ? floor : d;
  }

  /// Shortest rest for any channel: Settings -> Background refresh -> How often (1 hour when it's off). Test seam.
  static Duration Function() minRest =
      () => Duration(minutes: BackgroundRefresh.enabled.value ? BackgroundRefresh.everyMinutes.value : 60);

  /// A short, plain reason for a failed check (shown on the Following lists screen).
  static String failReason(Object e) {
    final t = '$e'.replaceFirst('Exception: ', '');
    final l = t.toLowerCase();
    if (l.contains('slow down') || l.contains('busy')) return 'archive asked to slow down';
    if (l.contains('429') || l.contains('rate')) return 'rate-limited';
    if (l.contains('timed out') || l.contains('timeout')) return 'timed out';
    if (l.contains('404') || l.contains('not found')) return 'not found';
    if (l.contains('network') || l.contains('socket') || l.contains('paused')) return 'no connection';
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  /// The saved check state of each entry of [profile], by [Follow.key].
  static Future<Map<String, FollowState>> statesOf(int profile) async {
    final src = followingKey(profile);
    return {for (final f in await FollowStore.follows(profile)) f.key: await _state(src, f)};
  }

  /// When an entry is next due on its own (opening the feed or the background task), or null if never checked.
  static DateTime? nextCheck(FollowState s, int nowMs) =>
      s.at == 0 ? null : DateTime.fromMillisecondsSinceEpoch(s.at).add(recheckAfter(s, nowMs));

  static final _force = <String>{};
  static final _logged = <String>{}; // sources whose round end is already in the pace log

  /// Pull-to-refresh: the next round checks every entry not checked in the last [freshFor], however quiet.
  static void forceFull(String source) => _force.add(source);
  static int pageSize = 100; // Arctic Shift maximum; fewer rows back means the entry has no older posts
  /// Refreshing an entry that already has posts only asks for this many newer ones (cheaper for the archive).
  static int refreshSize = 25;
  /// How far back a refresh round preloads on its own; older posts load when you scroll.
  static Duration subWindow = const Duration(days: 60);
  static Duration userWindow = const Duration(days: 180);
  /// Fill-back stops at this many posts per entry even if the window isn't reached (busy subreddits);
  /// scrolling still loads older ones.
  static int fillPosts = 500;
  /// Fill-back pages per entry per round (a guard: failed pages count too, so errors can't loop).
  static int fillPages = 10;
  /// Arctic Shift sets its limits by server load (its guide: "a couple requests per second" is fine) and answers
  /// "slow down" (HTTP 422) when busy, so the feed adapts: it starts at [minGap] between its requests, doubles
  /// the gap (up to [maxGap]) after every slow-down and eases back towards [minGap] after each success.
  static Duration minGap = const Duration(milliseconds: 1200);
  static Duration maxGap = const Duration(seconds: 15);
  static Duration gap = const Duration(milliseconds: 1200);

  /// Settings: two archive requests in flight at once (off by default). Drops back to one for two minutes
  /// after any slow-down.
  static final twoAtATime = ValueNotifier<bool>(false);
  static const _twoKey = 'followTwoAtATime';
  static DateTime _slowUntil = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> loadPrefs() async {
    twoAtATime.value = (await SharedPreferences.getInstance()).getBool(_twoKey) ?? false;
  }

  static Future<void> setTwoAtATime(bool on) async {
    twoAtATime.value = on;
    PaceLog.marker('setting', 'two_at_a_time=$on').ignore();
    await (await SharedPreferences.getInstance()).setBool(_twoKey, on);
  }

  /// Requests in flight per batch right now.
  static int get inFlight => twoAtATime.value && DateTime.now().isAfter(_slowUntil) ? 2 : 1;
  static DateTime? _last;

  /// Next gap after a request: doubled after a slow-down, 20 % shorter after a success, within the limits.
  static Duration nextGap(Duration g, {required bool busy}) {
    final ms = busy ? g.inMilliseconds * 2 : (g.inMilliseconds * 0.8).round();
    return Duration(milliseconds: ms.clamp(minGap.inMilliseconds, maxGap.inMilliseconds));
  }

  /// Bumps when posts were saved (the grid reloads from the database).
  static final version = ValueNotifier<int>(0);

  /// Posts a list's follows still cover: a followed subreddit's posts, or a followed user's posts.
  static bool Function(Post p) _covered(List<Follow> fs) {
    final subs = {for (final x in fs) if (x.kind == FollowKind.sub) x.name.toLowerCase()};
    final users = {for (final x in fs) if (x.kind == FollowKind.user) x.name.toLowerCase()};
    return (p) => subs.contains(p.subreddit.toLowerCase()) || users.contains(p.author.toLowerCase());
  }

  /// One-time clean-up per list: posts of follows removed before unfollowing dropped them (1.6.x).
  static Future<void> pruneOnce(int profile) async {
    final sp = await SharedPreferences.getInstance();
    final k = 'folPruned:$profile';
    if (sp.getBool(k) ?? false) return;
    final fs = await FollowStore.follows(profile);
    if (fs.isEmpty) return;
    final n = await Db.prunePosts(followingKey(profile), _covered(fs));
    await sp.setBool(k, true);
    if (n > 0) version.value++;
  }

  /// Unfollow [f] in [profile]: its saved posts leave the list too, except posts another follow still covers
  /// (a followed user's post in a followed subreddit stays while either is followed).
  static Future<int> unfollow(int profile, Follow f) async {
    await FollowStore.remove(profile, f);
    final n = await Db.dropPostsOf(followingKey(profile), f.name,
        byAuthor: f.kind == FollowKind.user, keep: _covered(await FollowStore.follows(profile)));
    version.value++;
    return n;
  }

  /// A user or subreddit page was opened in Deep Search. If a running refresh round still has it to check, it
  /// moves to the front. A page with nothing saved yet shows at once what your Following lists already saved
  /// for it; the archive then adds newer and older posts as usual (only once the saved posts are indexed: a
  /// full scan would cost more than it saves). Returns posts copied.
  static Future<int> channelOpened(String source) async {
    String? author, sub;
    if (isDeep(source)) {
      (author, sub) = deepParts(source);
    } else if (isSubSearch(source)) {
      final p = subParts(source);
      if (p.q.trim().isNotEmpty) return 0; // a search inside the subreddit: its own results only
      sub = p.sub;
      author = p.author.isEmpty ? null : p.author;
    } else {
      return 0;
    }
    bump(author: author, sub: sub);
    if (!Db.channelsReady || await Db.count(source) > 0) return 0;
    final posts = await Db.followedChannel(author: author, sub: sub);
    if (posts.isEmpty) return 0;
    await Db.savePosts(source, posts);
    return posts.length;
  }

  /// The channel the refresher is checking right now ([Follow.key]), or null.
  static final checking = ValueNotifier<String?>(null);

  /// The last channel check: its key, new posts, the pictures and videos in them, and why it failed (or null).
  static final lastCheck = ValueNotifier<({String key, int posts, int media, String? error})?>(null);

  /// Whether [key] is still waiting in [source]'s refresh round.
  static bool queued(String source, String key) => _round[source]?.any((f) => f.key == key) ?? false;

  /// A search on a Following list names one of its channels ("asianpussyass", "r/name" or "u/name"): check that
  /// channel next, even if it isn't due, so the search shows its newest posts. Returns the channel, or null.
  static Future<Follow?> searchedFor(String source, String query) async {
    final pid = followingProfile(source);
    if (pid == null) return null;
    final q = query.trim().toLowerCase();
    final m = RegExp(r'^/?([ru])/([a-z0-9_-]+)$').firstMatch(q) ?? RegExp(r'^()([a-z0-9_-]{3,})$').firstMatch(q);
    if (m == null) return null;
    final kind = m.group(1), name = m.group(2)!;
    final f = (await FollowStore.follows(pid)).where((x) =>
        x.name.toLowerCase() == name &&
        (kind == null || kind.isEmpty || (kind == 'r') == (x.kind == FollowKind.sub))).firstOrNull;
    if (f == null) return null;
    final queue = _round.putIfAbsent(source, () => []);
    queue.removeWhere((x) => x.key == f.key);
    queue.insert(0, f);
    _checked.putIfAbsent(source, () => (0, 0, 0));
    _retried.putIfAbsent(source, () => {});
    _filled.putIfAbsent(source, () => {});
    FollowingRefresher.start(source);
    return f;
  }

  /// Moves the follow for [author] (or else subreddit [sub]) to the front of every running refresh round.
  static void bump({String? author, String? sub}) {
    final kind = author != null ? FollowKind.user : FollowKind.sub;
    final name = (author ?? sub)?.toLowerCase();
    if (name == null) return;
    for (final q in _round.values) {
      final i = q.indexWhere((f) => f.kind == kind && f.name.toLowerCase() == name);
      if (i > 0) q.insert(0, q.removeAt(i));
    }
  }

  // One fetch at a time: the refresher, the grid and the background task share the archive's rate limit.
  static Future<void> _lock = Future<void>.value();
  static Future<T> _locked<T>(Future<T> Function() f) {
    final prev = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return prev.then((_) => f()).whenComplete(done.complete);
  }

  // Subreddits / users of each profile, lower-case, for the Following chips.
  static final _sets = <int, (Set<String>, Set<String>)>{};

  static Future<void> loadSets(int pid) async {
    final fs = await FollowStore.follows(pid);
    _sets[pid] = (
      {for (final f in fs) if (f.kind == FollowKind.sub) f.name.toLowerCase()},
      {for (final f in fs) if (f.kind == FollowKind.user) f.name.toLowerCase()},
    );
  }

  /// Applies the Following chips: posts made in a followed subreddit, or by a followed user.
  static List<Post> applyKind(List<Post> posts, String source) {
    final k = followingKind.value;
    final sets = _sets[followingProfile(source) ?? -1];
    if (k == 0 || sets == null) return posts;
    final (subs, users) = sets;
    return k == 1
        ? posts.where((p) => subs.contains(p.subreddit.toLowerCase())).toList()
        : posts.where((p) => users.contains(p.author.toLowerCase())).toList();
  }

  /// One page of an entry from Arctic Shift. Test seam.
  static Future<List<Map<String, dynamic>>> Function(Follow f, {int? after, int? before, int limit}) fetchPage = _arctic;

  // Background work: the page you're looking at gets the archive first.
  static Future<List<Map<String, dynamic>>> _arctic(Follow f, {int? after, int? before, int limit = 100}) => Archive.background(() => Archive.recentPosts(
      sub: f.kind == FollowKind.sub ? f.name : null, author: f.kind == FollowKind.user ? f.name : null, after: after, before: before, limit: limit));

  static Future<List<Map<String, dynamic>>> _paced(Follow f, {int? after, int? before, required int limit}) async {
    PaceLog.gapMs = gap.inMilliseconds;
    PaceLog.inFlight = inFlight;
    final l = _last;
    if (l != null) {
      final wait = gap - DateTime.now().difference(l);
      if (!wait.isNegative) await Future.delayed(wait);
    }
    try {
      final r = await fetchPage(f, after: after, before: before, limit: limit);
      gap = nextGap(gap, busy: false);
      return r;
    } catch (e) {
      if (_busy(e)) {
        gap = nextGap(gap, busy: true);
        _slowUntil = DateTime.now().add(const Duration(minutes: 2));
      }
      rethrow;
    } finally {
      _last = DateTime.now();
    }
  }

  static bool _busy(Object e) => RegExp(r'slow down|busy|rate|429|timed out|timeout', caseSensitive: false).hasMatch('$e');
  static final _retried = <String, Set<String>>{}; // source -> entries already retried this round

  static final _round = <String, List<Follow>>{}; // source -> entries still to refresh this round
  static final _checked = <String, (int, int, int)>{}; // source -> (checked, total, failed) this round
  static final _filled = <String, Map<String, int>>{}; // source -> fill-back pages used per entry this round
  static final _filling = <String, bool>{}; // source -> fill-back still has work this round

  /// Oldest created_utc (seconds) the round preloads for [f].
  static int horizon(Follow f, int nowMs) =>
      (nowMs - (f.kind == FollowKind.sub ? subWindow : userWindow).inMilliseconds) ~/ 1000;

  static String _unitKey(String source, Follow f) => '$source|${f.key}';

  static Future<FollowState> _state(String source, Follow f) async => FollowState.decode((await Db.cursor(_unitKey(source, f))).$1);
  static Future<void> _save(String source, Follow f, FollowState s) => Db.setCursor(_unitKey(source, f), s.encode());

  /// True once a refresh round was started for [source] this session.
  static bool started(String source) => _round.containsKey(source);

  /// Next batch for [source]; returns new post count, -1 when every entry is exhausted.
  static Future<int> fetchMore(String source, {bool fromStart = false, DateTime? now}) =>
      _locked(() => _fetchMore(source, fromStart: fromStart, now: now));

  static Future<int> _fetchMore(String source, {bool fromStart = false, DateTime? now}) async {
    final pid = followingProfile(source);
    if (pid == null) return -1;
    final follows = await FollowStore.follows(pid);
    if (follows.isEmpty) {
      followingStatus.value = 'This profile has no subreddits or users yet';
      await Db.setCursor(source, null);
      return -1;
    }
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    _sets[pid] = (
      {for (final f in follows) if (f.kind == FollowKind.sub) f.name.toLowerCase()},
      {for (final f in follows) if (f.kind == FollowKind.user) f.name.toLowerCase()},
    );
    final states = {for (final f in follows) f: await _state(source, f)};

    // Start a refresh round when the feed opens, on pull-to-refresh, or on the first call this session. Each entry
    // is due after its learned rest ([recheckAfter]); pull-to-refresh checks all but the ones just checked.
    if (fromStart || !_round.containsKey(source)) {
      final force = _force.remove(source);
      final stale = follows
          .where((f) => t - states[f]!.at >= (force ? freshFor : recheckAfter(states[f]!, t)).inMilliseconds)
          .toList()
        ..sort((a, b) => states[a]!.at.compareTo(states[b]!.at));
      _round[source] = stale;
      _logged.remove(source);
      PaceLog.marker('round_start', 'due=${stale.length};total=${follows.length};forced=$force').ignore();
      _checked[source] = (follows.length - stale.length, follows.length, 0);
      _retried[source] = {};
      _filled[source] = {};
    }
    final queue = _round[source]!;
    var (checked, total, failed) = _checked[source]!;
    total = follows.length;
    var added = 0;
    var used = 0;

    Future<int> save(Follow f, List<Map<String, dynamic>> rows) async {
      final posts = <Post>[];
      for (final d in rows) {
        final p = Post.fromJson(slimPost(d));
        if (p != null) posts.add(p);
      }
      final media = posts.fold<int>(0, (a, p) => a + p.media.length);
      await Db.savePosts(source, posts);
      added += posts.length;
      if (posts.isNotEmpty) version.value++;
      return media;
    }

    final filled = _filled.putIfAbsent(source, () => {});
    // Entries whose posts don't reach back to their window yet, newest gap first.
    List<Follow> toFill() => follows.where((f) {
          final s = states[f]!;
          return !s.done && s.oldest != null && s.oldest! > horizon(f, t) && s.n < fillPosts && (filled[f.key] ?? 0) < fillPages;
        }).toList()
          ..sort((a, b) => states[b]!.oldest!.compareTo(states[a]!.oldest!));

    void status([int? fillLeft]) {
      _checked[source] = (checked, total, failed);
      final fl = failed > 0 ? ' · $failed failed' : '';
      if (queue.isNotEmpty) {
        final mins = (queue.length * (gap.inMilliseconds + 1500) / 60000).ceil();
        followingStatus.value = 'Checked $checked of $total$fl · ~$mins min left';
      } else if (fillLeft != null && fillLeft > 0) {
        followingStatus.value = 'All $total checked$fl · filling back: $fillLeft to go';
      } else {
        followingStatus.value = 'All $total checked$fl · scroll for older posts';
      }
    }

    // 1) refresh: newest posts first (one at a time, or two side by side when that setting is on)
    Future<void> refreshOne(Follow f) async {
      final s = states[f]!;
      checking.value = f.key;
      try {
        final rows = await _paced(f, after: s.newest, limit: s.newest == null ? pageSize : refreshSize);
        final media = await save(f, rows);
        lastCheck.value = (key: f.key, posts: rows.length, media: media, error: null);
        s.n += rows.length;
        final ts = [for (final r in rows) _ts(r)].where((x) => x > 0).toList();
        if (ts.isNotEmpty) {
          final hi = ts.reduce((a, b) => a > b ? a : b), lo = ts.reduce((a, b) => a < b ? a : b);
          if (s.newest == null || hi > s.newest!) s.newest = hi;
          if (s.oldest == null) {
            s.oldest = lo;
            s.done = rows.length < pageSize;
          }
        } else if (s.newest == null) {
          s.done = true; // nothing at all for this entry
        }
        s.quiet = rows.isEmpty ? s.quiet + 1 : 0;
        s.fails = 0;
        s.err = null;
        s.at = t;
        await _save(source, f, s);
        checked++;
      } catch (e) {
        s.fails++;
        s.err = failReason(e);
        lastCheck.value = (key: f.key, posts: 0, media: 0, error: s.err);
        try {
          await _save(source, f, s);
        } catch (_) {}
        // First failure: try this entry again at the end of the round (after a pause if the archive said
        // to slow down). Second failure: count it and move on; the next round retries it.
        if (_retried.putIfAbsent(source, () => {}).add(f.key)) {
          queue.add(f); // the gap already grew if the archive said to slow down
        } else {
          failed++;
          checked++;
        }
      }
      if (checking.value == f.key) checking.value = null;
      status();
    }

    while (queue.isNotEmpty && used < budget) {
      final batch = <Follow>[];
      final n = inFlight;
      while (batch.length < n && queue.isNotEmpty && used < budget) {
        batch.add(queue.removeAt(0));
        used++;
      }
      await Future.wait(batch.map(refreshOne));
    }

    // 2) fill-back to the window, then 3) page back on scroll: entries with the newest unexplored history
    // first, so the feed stays roughly in date order.
    var fill = queue.isEmpty ? toFill() : <Follow>[];
    if (queue.isEmpty && used < budget) {
      final open = fill.isNotEmpty
          ? fill
          : (follows.where((f) => !states[f]!.done && states[f]!.oldest != null).toList()
            ..sort((a, b) => states[b]!.oldest!.compareTo(states[a]!.oldest!)));
      final filling = fill.isNotEmpty;
      for (final f in open.take(budget - used)) {
        final s = states[f]!;
        if (filling) filled[f.key] = (filled[f.key] ?? 0) + 1; // a failed page counts too, so errors can't loop
        try {
          final rows = await _paced(f, before: s.oldest, limit: pageSize);
          await save(f, rows);
          s.n += rows.length;
          final ts = [for (final r in rows) _ts(r)].where((x) => x > 0).toList();
          if (ts.isNotEmpty) s.oldest = ts.reduce((a, b) => a < b ? a : b);
          s.done = rows.length < pageSize || ts.isEmpty;
          await _save(source, f, s);
        } catch (_) {
          // try again on a later call (the gap already grew if it was a slow-down)
        }
      }
    }

    if (queue.isEmpty) fill = toFill();
    if (queue.isEmpty && _logged.add(source)) {
      PaceLog.marker('round_end', 'checked=$checked;total=$total;failed=$failed;gap_ms=${gap.inMilliseconds}').ignore();
    }
    _filling[source] = fill.isNotEmpty;
    status(fill.length);
    final allDone = queue.isEmpty && follows.every((f) => states[f]!.done);
    await Db.setCursor(source, allDone ? null : 'more');
    return allDone && added == 0 ? -1 : added;
  }

  /// True while a refresh round still has entries to check or fill back (it keeps going on its own until done).
  static bool refreshing(String source) => (_round[source]?.isNotEmpty ?? false) || (_filling[source] ?? false);

  static int _ts(Map d) {
    final v = d['created_utc'];
    return v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  }

  @visibleForTesting
  static List<Follow> debugRound(String source, List<Follow> fs) => _round[source] = [...fs];

  @visibleForTesting
  static void debugReset() {
    _round.clear();
    _force.clear();
    _slowUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _checked.clear();
    _retried.clear();
    _filled.clear();
    _filling.clear();
    _last = null;
    gap = minGap;
    followingKind.value = 0;
    FollowingRefresher.stop();
    followingStatus.value = null;
  }
}

/// Runs a profile's refresh round to the end, independent of any screen: switching tabs or opening the
/// viewer doesn't stop it. One source at a time; starting another one stops the previous loop.
class FollowingRefresher {
  static String? _source;
  static int _gen = 0;

  static bool running(String source) => _source == source;

  static void start(String source, {bool fromStart = false}) {
    if (_source == source && !fromStart) return;
    final gen = ++_gen;
    _source = source;
    () async {
      var first = true;
      try {
        while (gen == _gen) {
          final n = await Following.fetchMore(source, fromStart: first && fromStart);
          first = false;
          if (n < 0 || !Following.refreshing(source)) break;
        }
      } catch (_) {
        // a failed batch ends this loop; the next refresh or scroll starts it again
      } finally {
        if (gen == _gen) _source = null;
      }
    }();
  }

  static void stop() {
    _gen++;
    _source = null;
  }
}

/// How a followed subreddit or user is doing, from its saved check state.
enum ChannelHealth { unchecked, active, quiet, dead, failing }

/// Failing: its last 2+ checks failed. Dead: checked, and nothing ever found or its newest post is over
/// [deadAfter] old. Quiet: newest post over a week old. Active otherwise. Unchecked: never checked yet.
ChannelHealth healthOf(FollowState s, int nowMs, {Duration deadAfter = const Duration(days: 180)}) {
  if (s.fails >= 2) return ChannelHealth.failing;
  if (s.at == 0) return ChannelHealth.unchecked;
  final n = s.newest;
  if (n == null) return s.done ? ChannelHealth.dead : ChannelHealth.unchecked;
  final age = Duration(milliseconds: nowMs - n * 1000);
  if (age > deadAfter) return ChannelHealth.dead;
  if (age > const Duration(days: 7)) return ChannelHealth.quiet;
  return ChannelHealth.active;
}

String _iso(int? ms) => ms == null ? '' : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

/// One CSV row per entry: name, kind, status, last post, last checked, next check, posts saved, failures, last error.
String channelReportCsv(List<Follow> follows, Map<String, FollowState> states, int nowMs) {
  String q(String x) => x.contains(RegExp('[",\n]')) ? '"${x.replaceAll('"', '""').replaceAll('\n', ' ')}"' : x;
  final rows = <String>['name,kind,status,last_post_utc,last_checked_utc,next_check_utc,posts_saved,failures_in_a_row,last_error'];
  for (final f in follows) {
    final s = states[f.key] ?? FollowState();
    rows.add([
      q(f.label), f.kind == FollowKind.sub ? 'subreddit' : 'user', healthOf(s, nowMs).name,
      _iso(s.newest == null ? null : s.newest! * 1000), _iso(s.at == 0 ? null : s.at),
      _iso(Following.nextCheck(s, nowMs)?.millisecondsSinceEpoch), s.n, s.fails, q(s.err ?? ''),
    ].join(','));
  }
  return rows.join('\n');
}
