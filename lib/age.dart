/// How long ago a post went up, short enough for a tile: "now", "5m", "3h", "2d", "5mo", "2y".
String shortAge(int createdSecs, {DateTime? now}) {
  if (createdSecs <= 0) return '';
  final d = (now ?? DateTime.now()).difference(DateTime.fromMillisecondsSinceEpoch(createdSecs * 1000));
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 30) return '${d.inDays}d';
  if (d.inDays < 365) return '${d.inDays ~/ 30}mo';
  return '${d.inDays ~/ 365}y';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// When a post went up, in local time, and how long ago: "22 Nov 2026, 14:05 · 3d ago".
String postedWhen(int createdSecs, {DateTime? now}) {
  if (createdSecs <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(createdSecs * 1000).toLocal();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final a = shortAge(createdSecs, now: now);
  return '${t.day} ${_months[t.month - 1]} ${t.year}, $hm · ${a == 'now' ? 'just now' : '$a ago'}';
}
