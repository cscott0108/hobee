import 'package:flutter/material.dart';
import 'app_lock.dart';
import 'following.dart';
import 'follows.dart';

/// Top-bar button on a subreddit or user page: follow it in one of your lists. Filled when a list already
/// follows it; tap to see your lists with checkmarks and add or remove it.
class FollowButton extends StatelessWidget {
  final Follow follow;
  const FollowButton(this.follow, {super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: FollowStore.version,
        builder: (_, _, _) => FutureBuilder<Set<int>>(
          future: FollowStore.listsWith(follow),
          builder: (c, s) {
            final on = (s.data ?? const {}).isNotEmpty;
            final sub = follow.kind == FollowKind.sub;
            return IconButton(
              key: Key(on ? 'following-button' : 'follow-button'),
              tooltip: on ? 'Following ${follow.label} (change)' : 'Follow ${follow.label}',
              icon: Icon(on
                  ? (sub ? Icons.bookmark_added : Icons.how_to_reg)
                  : (sub ? Icons.bookmark_add_outlined : Icons.person_add_alt_1_outlined)),
              color: on ? Theme.of(c).colorScheme.primary : null,
              onPressed: () => showFollowSheet(c, follow),
            );
          },
        ),
      );
}

/// Your lists with a checkmark where [f] is followed; tap to add or remove (removing also drops its saved posts).
Future<void> showFollowSheet(BuildContext context, Follow f) async {
  final lists = await FollowStore.profiles();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => ValueListenableBuilder(
      valueListenable: FollowStore.version,
      builder: (_, _, _) => FutureBuilder<Set<int>>(
        future: FollowStore.listsWith(f),
        builder: (_, s) {
          final have = s.data ?? const <int>{};
          return SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Follow ${f.label} in', style: Theme.of(sheet).textTheme.titleMedium),
              ),
              for (final p in lists)
                CheckboxListTile(
                  key: Key('follow-list-${p.id}'),
                  value: have.contains(p.id),
                  title: Text(p.name),
                  onChanged: s.connectionState != ConnectionState.done
                      ? null
                      : (on) async {
                          // A locked list needs its unlock before it can be changed.
                          if (!await AppLock.allowProfile(p.id, p.name)) return;
                          if (on == true) {
                            await FollowStore.add(p.id, [f]);
                          } else {
                            await Following.unfollow(p.id, f);
                          }
                        },
                ),
              const SizedBox(height: 8),
            ]),
          );
        },
      ),
    ),
  );
}
